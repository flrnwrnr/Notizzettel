import Foundation
import PencilKit
import XCTest

@testable import Notizen

@MainActor
final class AutomaticDueDateTests: XCTestCase {
    private let bounds = CGRect(x: 20, y: 20, width: 120, height: 30)
    private let reference = TaskDueDate(year: 2026, month: 12, day: 31)

    func testCommittedRelativeDateUsesPersistedAnchorAndSurvivesReopen() async throws {
        let source = CandidateText("Bericht bis morgen")
        let task = makeTask(
            text: "Bericht", reference: reference, trusted: true
        )
        let session = makeSession(source: source, savedTasks: [task])
        let drawing = PKDrawing().dataRepresentation()

        await commit(session, drawing: drawing)
        let inferred = try XCTUnwrap(session.tasks.first)
        XCTAssertEqual(inferred.dueDate, TaskDueDate(year: 2027, month: 1, day: 1))
        XCTAssertEqual(inferred.dueDateSource, .automatic)
        XCTAssertEqual(inferred.dueDateReferenceDate, reference)

        let reopened = makeSession(source: source, savedTasks: [inferred])
        await commit(reopened, drawing: drawing)
        XCTAssertEqual(reopened.tasks.first?.dueDate, inferred.dueDate)
        XCTAssertEqual(reopened.tasks.first?.dueDateReferenceDate, reference)
    }

    func testLegacyRelativeDateIsProposalWithNoteDateAnchor() async throws {
        let source = CandidateText("Bericht bis morgen")
        let legacy = makeTask(text: "Bericht")
        let session = makeSession(
            source: source, savedTasks: [legacy], legacyReferenceDate: reference.date
        )

        await commit(session, drawing: PKDrawing().dataRepresentation())
        let task = try XCTUnwrap(session.tasks.first)
        XCTAssertNil(task.dueDate)
        XCTAssertEqual(task.dueDateProposal?.date, TaskDueDate(year: 2027, month: 1, day: 1))
        XCTAssertEqual(task.dueDateReferenceDate, reference)
        XCTAssertFalse(task.dueDateReferenceIsTrusted)
    }

    func testManualSameValueAndNilOverrideStopLaterOCRInference() async throws {
        let source = CandidateText("Bericht bis 2027-01-02")
        let task = makeTask(text: "Bericht", reference: reference, trusted: true)
        let session = makeSession(source: source, savedTasks: [task])
        let drawing = PKDrawing().dataRepresentation()
        await commit(session, drawing: drawing)
        let id = task.id
        let inferredDate = try XCTUnwrap(session.tasks.first?.dueDate)

        session.updateDueDate(inferredDate, for: id)
        XCTAssertEqual(session.tasks.first?.dueDateSource, .manual)
        await source.set("Bericht bis 2027-01-05")
        session.recognizeNow()
        await session.finishPendingRecognition()
        XCTAssertEqual(session.tasks.first?.dueDate, inferredDate)

        session.updateDueDate(nil, for: id)
        XCTAssertNil(session.tasks.first?.dueDate)
        XCTAssertEqual(session.tasks.first?.dueDateSource, .manual)
        session.recognizeNow()
        await session.finishPendingRecognition()
        XCTAssertNil(session.tasks.first?.dueDate)
        XCTAssertNil(session.tasks.first?.dueDateProposal)
    }

    func testLinkedFreshTaskKeepsTitleWhileNewOCRChangesAutomaticDate() async throws {
        let source = CandidateText("Bericht bis 2027-01-02")
        let task = makeTask(
            text: "Bericht", reminderIdentifier: "reminder-1",
            reference: reference, trusted: true
        )
        let session = makeSession(source: source, savedTasks: [task])
        let drawing = PKDrawing().dataRepresentation()
        await commit(session, drawing: drawing)

        XCTAssertEqual(session.tasks.first?.recognizedText, "Bericht")
        XCTAssertEqual(session.tasks.first?.dueDate, TaskDueDate(year: 2027, month: 1, day: 2))
        XCTAssertEqual(session.tasks.first?.dueDateSource, .automatic)
        XCTAssertTrue(try XCTUnwrap(session.tasks.first).reminderDueDateSyncPending)

        await source.set("Bericht bis 2027-01-03")
        session.recognizeNow()
        await session.finishPendingRecognition()
        XCTAssertEqual(session.tasks.first?.recognizedText, "Bericht")
        XCTAssertEqual(session.tasks.first?.dueDate, TaskDueDate(year: 2027, month: 1, day: 3))
    }

    func testLegacyExternalNilTombstoneAndMetadataSurviveOCRMerge() throws {
        var legacy = makeTask(text: "Bericht", reminderIdentifier: "reminder-1")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        var oldObject = object
        for key in ["dueDateSource", "dueDateReferenceDate", "dueDateReferenceIsTrusted",
                    "dueDateLastAnalyzedText", "dueDateProposal"] {
            oldObject.removeValue(forKey: key)
        }
        legacy = try JSONDecoder().decode(
            RecognizedTask.self, from: JSONSerialization.data(withJSONObject: oldObject)
        )
        XCTAssertEqual(legacy.dueDateSource, .external)

        let merged = try XCTUnwrap(TaskRecognitionSession.merge([
            TaskCandidate(bounds: bounds, text: "Bericht bis morgen", confidence: 0.98,
                          isChecked: false)
        ], with: [legacy]).first)
        XCTAssertNil(merged.dueDate)
        XCTAssertEqual(merged.dueDateSource, .external)
        XCTAssertEqual(merged.id, legacy.id)
    }

    func testReminderReadbackTakesOwnershipAndBlocksLaterOCR() async throws {
        let source = CandidateText("Bericht bis 2027-01-02")
        var task = makeTask(
            text: "Bericht", reminderIdentifier: "reminder-1",
            reference: reference, trusted: true
        )
        task.dueDate = TaskDueDate(year: 2027, month: 1, day: 2)
        task.dueDateSource = .automatic
        let store = ExternalDateStore()
        store.records[task.id] = ReminderRecord(
            taskIdentifier: task.id, reminderIdentifier: "reminder-1",
            calendarIdentifier: "list-1", isCompleted: false,
            dueDate: TaskDueDate(year: 2027, month: 1, day: 5)
        )
        let defaults = UserDefaults(suiteName: "AutomaticDueDateTests-\(UUID().uuidString)")!
        let service = ReminderService(store: store, userDefaults: defaults)
        let session = makeSession(source: source, savedTasks: [task])
        session.configureReminders(service)
        await session.refreshReminderStatuses()

        XCTAssertEqual(session.tasks.first?.dueDate, TaskDueDate(year: 2027, month: 1, day: 5))
        XCTAssertEqual(session.tasks.first?.dueDateSource, .external)
        await source.set("Bericht bis 2027-01-07")
        await commit(session, drawing: PKDrawing().dataRepresentation())
        XCTAssertEqual(session.tasks.first?.dueDate, TaskDueDate(year: 2027, month: 1, day: 5))
        XCTAssertTrue(store.dateWrites.isEmpty)

        store.records[task.id] = ReminderRecord(
            taskIdentifier: task.id, reminderIdentifier: "reminder-1",
            calendarIdentifier: "list-1", isCompleted: false, dueDate: nil
        )
        await session.refreshReminderStatuses()
        XCTAssertNil(session.tasks.first?.dueDate)
        XCTAssertEqual(session.tasks.first?.dueDateSource, .external)
        XCTAssertTrue(store.dateWrites.isEmpty)
    }

    func testTypingOnlyProposesUntilCommittedRecognition() async throws {
        let source = CandidateText("Bericht")
        let task = makeTask(text: "Bericht", reference: reference, trusted: true)
        let session = makeSession(source: source, savedTasks: [task])

        session.updateTitle("Bericht bis 2027-01-02", for: task.id)
        XCTAssertNil(session.tasks.first?.dueDate)
        XCTAssertEqual(session.tasks.first?.dueDateProposal?.date,
                       TaskDueDate(year: 2027, month: 1, day: 2))
    }

    func testActivityElsewhereDoesNotTrustOldInkButNewBlankRowDoes() async throws {
        let oldReference = TaskDueDate(year: 2026, month: 1, day: 1)
        let oldInk = line(from: CGPoint(x: 24, y: 25), to: CGPoint(x: 50, y: 25))
        let unrelatedInk = line(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 430, y: 400))
        let baseline = PKDrawing(strokes: [oldInk]).dataRepresentation()
        let changed = PKDrawing(strokes: [oldInk, unrelatedInk]).dataRepresentation()

        let oldSession = makeSession(
            source: CandidateText("Bericht bis morgen"), savedTasks: [],
            legacyReferenceDate: oldReference.date
        )
        oldSession.seedRemovalEvidence(from: baseline)
        oldSession.drawingActivityBegan()
        oldSession.drawingActivityEnded(changed)
        await oldSession.finishPendingRecognition()
        XCTAssertNil(oldSession.tasks.first?.dueDate)
        XCTAssertEqual(oldSession.tasks.first?.dueDateProposal?.date,
                       TaskDueDate(year: 2026, month: 1, day: 2))
        XCTAssertFalse(try XCTUnwrap(oldSession.tasks.first).dueDateReferenceIsTrusted)

        let newBounds = CGRect(x: 20, y: 120, width: 120, height: 30)
        let newInk = line(from: CGPoint(x: 25, y: 125), to: CGPoint(x: 50, y: 125))
        let newSession = makeSession(
            source: CandidateText("Bericht bis morgen"), savedTasks: [],
            legacyReferenceDate: oldReference.date, candidateBounds: newBounds
        )
        newSession.seedRemovalEvidence(from: baseline)
        newSession.drawingActivityBegan()
        newSession.drawingActivityEnded(
            PKDrawing(strokes: [oldInk, newInk]).dataRepresentation()
        )
        await newSession.finishPendingRecognition()
        XCTAssertNotNil(newSession.tasks.first?.dueDate)
        XCTAssertEqual(newSession.tasks.first?.dueDateSource, .automatic)
        XCTAssertTrue(try XCTUnwrap(newSession.tasks.first).dueDateReferenceIsTrusted)
    }

    private func makeTask(
        text: String,
        reminderIdentifier: String? = nil,
        reference: TaskDueDate? = nil,
        trusted: Bool = false
    ) -> RecognizedTask {
        RecognizedTask(
            id: UUID(), bounds: bounds, recognizedText: text, correctedText: nil,
            confidence: 0.98, isChecked: false,
            reminderIdentifier: reminderIdentifier,
            reminderCalendarIdentifier: reminderIdentifier.map { _ in "list-1" },
            reminderStatus: reminderIdentifier.map { _ in .open },
            dueDateReferenceDate: reference, dueDateReferenceIsTrusted: trusted
        )
    }

    private func makeSession(
        source: CandidateText,
        savedTasks: [RecognizedTask],
        legacyReferenceDate: Date? = nil,
        candidateBounds: CGRect? = nil
    ) -> TaskRecognitionSession {
        let bounds = candidateBounds ?? self.bounds
        let session = TaskRecognitionSession(
            debounceDuration: .zero,
            recognize: { _ in
                [TaskCandidate(bounds: bounds, text: await source.get(),
                               confidence: 0.98, isChecked: false)]
            }
        )
        session.configure(
            noteID: UUID(), savedTasks: savedTasks,
            legacyReferenceDate: legacyReferenceDate
        ) { _, _ in }
        return session
    }

    private func commit(_ session: TaskRecognitionSession, drawing: Data) async {
        session.drawingDidChange(drawing, automatically: false)
        await session.finishPendingRecognition()
    }

    private func line(from start: CGPoint, to end: CGPoint) -> PKStroke {
        let points = [start, end].enumerated().map { index, location in
            PKStrokePoint(
                location: location, timeOffset: Double(index) * 0.1,
                size: CGSize(width: 5, height: 5), opacity: 1, force: 1,
                azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: .distantPast)
        )
    }
}

private actor CandidateText {
    private var text: String
    init(_ text: String) { self.text = text }
    func get() -> String { text }
    func set(_ text: String) { self.text = text }
}

@MainActor
private final class ExternalDateStore: ReminderStore {
    var records: [UUID: ReminderRecord] = [:]
    var dateWrites: [TaskDueDate?] = []

    func authorizationStatus() -> ReminderAuthorization { .fullAccess }
    func requestFullAccess() async throws -> Bool { true }
    func writableLists() -> [ReminderList] {
        [ReminderList(id: "list-1", title: "Notizen", sourceTitle: "iCloud")]
    }
    func defaultListIdentifier() -> String? { "list-1" }
    func createReminder(
        title: String, isCompleted: Bool, listIdentifier: String, taskIdentifier: UUID
    ) async throws -> String { "reminder-1" }
    func setReminderCompleted(identifier: String, isCompleted: Bool) async throws {}
    func setReminderDueDate(identifier: String, dueDate: TaskDueDate?) async throws {
        dateWrites.append(dueDate)
    }
    func fetchReminderRecords(
        for requests: [ReminderLookupRequest]
    ) async throws -> ReminderReadSnapshot {
        ReminderReadSnapshot(
            recordsByTaskIdentifier: records, readableCalendarIdentifiers: ["list-1"]
        )
    }
}
