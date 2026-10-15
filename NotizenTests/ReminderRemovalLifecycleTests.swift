import Foundation
import PencilKit
import UIKit
import XCTest

@testable import Notizen

@MainActor
final class ReminderRemovalLifecycleTests: XCTestCase {
    private let boxBounds = CGRect(x: 40, y: 40, width: 36, height: 36)

    func testErasingFrameDeletesLinkedReminderAndUndoRecreatesWithoutDuplicate() async throws {
        let box = square()
        let drawing = PKDrawing(strokes: [box])
        let store = RemovalReminderStore()
        let task = linkedTask()
        store.put(task)
        let session = makeSession(store: store, task: task)

        session.drawingDidChange(drawing.dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        XCTAssertGreaterThanOrEqual(session.tasks[0].checkboxInkEvidence?.count ?? 0, 12)

        session.drawingDidChange(PKDrawing().dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        XCTAssertEqual(store.removalCount, 1)
        XCTAssertTrue(session.tasks[0].wasRemovedFromDrawing)
        XCTAssertEqual(session.tasks[0].reminderStatus, .deleted)
        XCTAssertEqual(session.tasks[0].dueDate, task.dueDate)

        session.drawingDidChange(drawing.dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        await session.awaitReminderOperations()
        XCTAssertEqual(store.creationCount, 1)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(session.tasks[0].id, task.id)
        XCTAssertFalse(session.tasks[0].wasRemovedFromDrawing)
        XCTAssertFalse(session.tasks[0].reminderRestorePending)
        XCTAssertEqual(session.tasks[0].dueDate, task.dueDate)
    }

    func testCheckmarkOnlyRemovalReopensWithoutDeleting() async throws {
        let box = square()
        let tick = polyline([CGPoint(x: 48, y: 59), CGPoint(x: 54, y: 65), CGPoint(x: 69, y: 48)])
        let checked = PKDrawing(strokes: [box, tick])
        let unchecked = PKDrawing(strokes: [box])
        let store = RemovalReminderStore()
        var task = linkedTask()
        task.isChecked = true
        task.reminderLastSyncedIsChecked = true
        task.reminderStatus = .completed
        store.put(task)
        let session = makeSession(store: store, task: task)
        session.drawingDidChange(checked.dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()

        session.drawingDidChange(unchecked.dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        XCTAssertEqual(store.removalCount, 0)
        XCTAssertEqual(store.completionUpdates, [false])
        XCTAssertEqual(session.tasks[0].reminderStatus, .open)
        XCTAssertFalse(session.tasks[0].wasRemovedFromDrawing)
    }

    func testOCRMissThenEraseStillDeletesOnlyAfterFrameDisappears() async throws {
        let drawing = PKDrawing(strokes: [square()])
        let store = RemovalReminderStore()
        var task = linkedTask()
        task.checkboxInkEvidence = CheckboxRemovalEvidence.samples(in: drawing, near: boxBounds)
        task.checkboxStrokeEvidence = CheckboxRemovalEvidence.strokeEvidence(in: drawing, near: boxBounds)
        store.put(task)
        let session = makeSession(store: store, task: task, recognize: { _ in [] })
        session.drawingDidChange(drawing.dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        XCTAssertEqual(store.removalCount, 0)
        XCTAssertFalse(session.tasks[0].isPresent)

        session.drawingDidChange(PKDrawing().dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        XCTAssertEqual(store.removalCount, 1)
        XCTAssertTrue(session.tasks[0].wasRemovedFromDrawing)
    }

    func testLegacyTaskSeededFromSavedDrawingCanBeErasedImmediately() async throws {
        let drawing = PKDrawing(strokes: [square()])
        let store = RemovalReminderStore()
        let task = linkedTask()
        store.put(task)
        let session = makeSession(store: store, task: task)
        XCTAssertNil(session.tasks[0].checkboxInkEvidence)
        session.seedRemovalEvidence(from: drawing.dataRepresentation())
        XCTAssertGreaterThanOrEqual(session.tasks[0].checkboxInkEvidence?.count ?? 0, 12)

        session.drawingDidChange(PKDrawing().dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        XCTAssertEqual(store.removalCount, 1)
        XCTAssertTrue(session.tasks[0].wasRemovedFromDrawing)
    }

    func testUnknownLegacyGeometryDoesNotDeleteOnEmptyOCR() async throws {
        let store = RemovalReminderStore()
        let task = linkedTask()
        store.put(task)
        let session = makeSession(store: store, task: task)
        session.seedRemovalEvidence(from: PKDrawing().dataRepresentation())

        session.drawingDidChange(PKDrawing().dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        XCTAssertEqual(store.removalCount, 0)
        XCTAssertFalse(session.tasks[0].wasRemovedFromDrawing)
    }

    func testMovingCheckboxKeepsIdentityThroughRepeatedRecognition() async throws {
        let box = square()
        let store = RemovalReminderStore()
        let task = linkedTask()
        store.put(task)
        let session = makeSession(store: store, task: task)
        session.drawingDidChange(PKDrawing(strokes: [box]).dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()

        var moved = box
        moved.transform = CGAffineTransform(translationX: 160, y: 160)
        session.drawingDidChange(PKDrawing(strokes: [moved]).dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        session.recognizeNow()
        await session.finishPendingRecognition()

        XCTAssertEqual(store.removalCount, 0)
        XCTAssertEqual(session.tasks.count, 1)
        XCTAssertEqual(session.tasks[0].id, task.id)
        XCTAssertTrue(session.tasks[0].isPresent)
    }

    func testCopyingCheckboxKeepsOriginalLinkOnOriginalFrame() async throws {
        let box = square()
        let store = RemovalReminderStore()
        let task = linkedTask()
        store.put(task)
        let session = makeSession(store: store, task: task)
        session.drawingDidChange(PKDrawing(strokes: [box]).dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()

        var copy = box
        copy.transform = CGAffineTransform(translationX: 150, y: 0)
        session.drawingDidChange(PKDrawing(strokes: [box, copy]).dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        session.recognizeNow()
        await session.finishPendingRecognition()

        XCTAssertEqual(store.removalCount, 0)
        let original = try XCTUnwrap(session.tasks.first(where: { $0.id == task.id }))
        XCTAssertEqual(original.bounds.midX, boxBounds.midX, accuracy: 8)
        XCTAssertTrue(original.isPresent)
        XCTAssertEqual(session.tasks.filter { $0.reminderIdentifier != nil }.count, 1)
    }

    func testErasingOldFrameWhileDrawingNewOneDeletesOnlyOldLink() async throws {
        let original = square()
        let replacement = polyline([
            CGPoint(x: 220, y: 40), CGPoint(x: 256, y: 40), CGPoint(x: 256, y: 76),
            CGPoint(x: 220, y: 76), CGPoint(x: 220, y: 40)
        ])
        let store = RemovalReminderStore()
        let task = linkedTask()
        store.put(task)
        let session = makeSession(store: store, task: task)
        session.drawingDidChange(PKDrawing(strokes: [original]).dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()

        session.drawingDidChange(PKDrawing(strokes: [replacement]).dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        XCTAssertEqual(store.removalCount, 1)
        XCTAssertTrue(try XCTUnwrap(session.tasks.first(where: { $0.id == task.id })).wasRemovedFromDrawing)
        XCTAssertEqual(session.tasks.filter { $0.isPresent && $0.reminderIdentifier == nil }.count, 1)
    }

    func testUndoWhileDeletionInFlightRestoresLinkedReminder() async throws {
        let drawing = PKDrawing(strokes: [square()])
        let store = RemovalReminderStore()
        let task = linkedTask()
        store.put(task)
        let session = makeSession(store: store, task: task)
        session.drawingDidChange(drawing.dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        store.suspendRemoval = true

        session.drawingDidChange(PKDrawing().dataRepresentation(), automatically: false)
        let draining = Task { await session.finishPendingRecognition() }
        try await waitUntil("deletion to start") { store.removalStarted }
        session.drawingDidChange(drawing.dataRepresentation(), automatically: false)
        store.finishRemoval()
        await draining.value
        await session.finishPendingRecognition()
        await session.awaitReminderOperations()

        XCTAssertEqual(store.removalCount, 1)
        XCTAssertEqual(store.creationCount, 1)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(session.tasks.first?.id, task.id)
        XCTAssertFalse(session.tasks[0].reminderRestorePending)
    }

    func testRedoDuringNestedRestorationDeletesReminderAgain() async throws {
        let drawing = PKDrawing(strokes: [square()])
        let store = RemovalReminderStore()
        let task = linkedTask()
        store.put(task)
        let session = makeSession(store: store, task: task)
        session.drawingDidChange(drawing.dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        store.suspendRemoval = true
        store.suspendCreation = true

        session.drawingDidChange(PKDrawing().dataRepresentation(), automatically: false)
        let draining = Task { await session.finishPendingRecognition() }
        try await waitUntil("deletion to start") { store.removalStarted }
        session.drawingDidChange(drawing.dataRepresentation(), automatically: false)
        try await waitUntil("Undo recognition") { session.tasks[0].isPresent }
        store.finishRemoval()
        try await waitUntil("restoration to start") { store.creationStarted }
        session.drawingDidChange(PKDrawing().dataRepresentation(), automatically: false)
        try await waitUntil("redo recognition") { session.tasks[0].wasRemovedFromDrawing }
        store.finishCreation()

        await draining.value
        await session.finishPendingRecognition()
        await session.awaitReminderOperations()
        XCTAssertEqual(store.removalCount, 2)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(session.tasks[0].wasRemovedFromDrawing)
        XCTAssertFalse(session.tasks[0].reminderRemovalPending)
    }

    func testExternalDeletionBeforeErasureDoesNotAuthorizeUndoRestore() async throws {
        let drawing = PKDrawing(strokes: [square()])
        let store = RemovalReminderStore()
        let task = linkedTask()
        store.put(task)
        let session = makeSession(store: store, task: task)
        session.drawingDidChange(drawing.dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        store.records.removeValue(forKey: task.id)
        await session.refreshReminderStatuses()
        try await waitUntil { session.tasks[0].reminderStatus == .deleted }
        XCTAssertEqual(session.tasks[0].reminderStatus, .deleted)

        session.drawingDidChange(PKDrawing().dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        session.drawingDidChange(drawing.dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()

        XCTAssertEqual(store.removalCount, 0)
        XCTAssertEqual(store.creationCount, 0)
        XCTAssertFalse(session.tasks[0].reminderRestorePending)
    }

    func testFailedDeletionRetainsPendingStateAndRetryWorksWithoutNewDrawing() async throws {
        let drawing = PKDrawing(strokes: [square()])
        let store = RemovalReminderStore()
        let task = linkedTask()
        store.put(task)
        let session = makeSession(store: store, task: task)
        session.drawingDidChange(drawing.dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        store.removalError = ReminderServiceError.saveFailed("Test")

        session.drawingDidChange(PKDrawing().dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()
        XCTAssertTrue(session.tasks[0].reminderRemovalPending)
        XCTAssertNotNil(session.tasks[0].reminderSyncError)
        store.removalError = nil
        session.retryReminderSync(for: task.id)
        await session.awaitReminderOperations()
        XCTAssertEqual(store.removalCount, 1)
        XCTAssertFalse(session.tasks[0].reminderRemovalPending)
    }

    func testIgnoredProposalSurvivesMergeAndLegacyDecoding() throws {
        var task = linkedTask()
        task.reminderIdentifier = nil
        task.isIgnored = true
        let candidate = TaskCandidate(bounds: task.bounds, text: "Other OCR", confidence: 0.9, isChecked: false)
        XCTAssertTrue(TaskRecognitionSession.merge([candidate], with: [task])[0].isIgnored)
        XCTAssertTrue(TaskRecognitionSession.merge([], with: [task])[0].isIgnored)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        json.removeValue(forKey: "isIgnored")
        json.removeValue(forKey: "reminderRemovalPending")
        json.removeValue(forKey: "wasRemovedFromDrawing")
        json.removeValue(forKey: "reminderRestorePending")
        json.removeValue(forKey: "checkboxInkEvidence")
        json.removeValue(forKey: "checkboxStrokeEvidence")
        let decoded = try JSONDecoder().decode(RecognizedTask.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.isIgnored)
        XCTAssertFalse(decoded.reminderRemovalPending)
        XCTAssertNil(decoded.checkboxInkEvidence)
    }

    private func makeSession(
        store: RemovalReminderStore,
        task: RecognizedTask,
        recognize: (@Sendable (Data) async throws -> [TaskCandidate])? = nil
    ) -> TaskRecognitionSession {
        let defaults = UserDefaults(suiteName: "RemovalTests.\(UUID().uuidString)")!
        let service = ReminderService(store: store, userDefaults: defaults)
        let session = TaskRecognitionSession(debounceDuration: .zero, recognize: recognize ?? { data in
            let drawing = try PKDrawing(data: data)
            let sampled = TaskRecognitionEngine.sampleVisibleGeometry(from: drawing)
            let boxes = CheckboxDetector.detect(
                strokes: sampled,
                pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800), limit: 30
            )
            return boxes.map {
                TaskCandidate(bounds: $0.bounds, text: "Milk", confidence: 1,
                              isChecked: CheckboxDetector.isChecked($0, among: sampled))
            }
        })
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }
        return session
    }

    private func linkedTask() -> RecognizedTask {
        RecognizedTask(id: UUID(), bounds: boxBounds, recognizedText: "Milk", correctedText: nil,
                       confidence: 1, isChecked: false, reminderIdentifier: "original",
                       reminderCalendarIdentifier: "list", reminderStatus: .open,
                       reminderLastSyncedIsChecked: false,
                       dueDate: TaskDueDate(year: 2026, month: 12, day: 24))
    }

    private func square() -> PKStroke {
        polyline([CGPoint(x: 40, y: 40), CGPoint(x: 76, y: 40), CGPoint(x: 76, y: 76),
                  CGPoint(x: 40, y: 76), CGPoint(x: 40, y: 40)])
    }

    private func polyline(_ corners: [CGPoint]) -> PKStroke {
        let locations = zip(corners, corners.dropFirst()).flatMap { a, b -> [CGPoint] in
            (0..<12).map { index in
                let t = CGFloat(index) / 12
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        } + [corners.last!]
        let points = locations.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01,
                          size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    private func waitUntil(
        _ description: String = "reminder operation",
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitTimeout(description: description)
    }

    private struct WaitTimeout: LocalizedError {
        let description: String
        var errorDescription: String? { "Timed out waiting for \(description)" }
    }
}

@MainActor
private final class RemovalReminderStore: ReminderStore {
    var records: [UUID: ReminderRecord] = [:]
    var removalCount = 0
    var creationCount = 0
    var completionUpdates: [Bool] = []
    var removalError: Error?
    var suspendRemoval = false
    var removalStarted = false
    private var removalContinuation: CheckedContinuation<Void, Never>?
    var suspendCreation = false
    var creationStarted = false
    private var creationContinuation: CheckedContinuation<Void, Never>?

    func put(_ task: RecognizedTask) {
        records[task.id] = ReminderRecord(taskIdentifier: task.id,
                                          reminderIdentifier: task.reminderIdentifier ?? "original",
                                          calendarIdentifier: "list", isCompleted: task.isChecked,
                                          dueDate: task.dueDate)
    }
    func authorizationStatus() -> ReminderAuthorization { .fullAccess }
    func requestFullAccess() async throws -> Bool { true }
    func writableLists() -> [ReminderList] { [ReminderList(id: "list", title: "List", sourceTitle: "Test")] }
    func defaultListIdentifier() -> String? { "list" }
    func createReminder(title: String, isCompleted: Bool, listIdentifier: String,
                        taskIdentifier: UUID) async throws -> String {
        creationStarted = true
        if suspendCreation {
            await withCheckedContinuation { continuation in
                creationContinuation = continuation
            }
        }
        creationCount += 1
        let id = "created-\(creationCount)"
        records[taskIdentifier] = ReminderRecord(taskIdentifier: taskIdentifier,
                                                 reminderIdentifier: id, calendarIdentifier: listIdentifier,
                                                 isCompleted: isCompleted)
        return id
    }
    func createReminder(title: String, isCompleted: Bool, dueDate: TaskDueDate?,
                        listIdentifier: String, taskIdentifier: UUID) async throws -> String {
        let id = try await createReminder(title: title, isCompleted: isCompleted,
                                          listIdentifier: listIdentifier, taskIdentifier: taskIdentifier)
        if let dueDate, let record = records[taskIdentifier] {
            records[taskIdentifier] = ReminderRecord(taskIdentifier: taskIdentifier,
                                                     reminderIdentifier: id, calendarIdentifier: listIdentifier,
                                                     isCompleted: record.isCompleted, dueDate: dueDate)
        }
        return id
    }
    func setReminderCompleted(identifier: String, isCompleted: Bool) async throws {
        completionUpdates.append(isCompleted)
        if let key = records.first(where: { $0.value.reminderIdentifier == identifier })?.key,
           let record = records[key] {
            records[key] = ReminderRecord(taskIdentifier: key, reminderIdentifier: identifier,
                                          calendarIdentifier: record.calendarIdentifier,
                                          isCompleted: isCompleted, dueDate: record.dueDate)
        }
    }
    func removeReminder(identifier: String, taskIdentifier: UUID,
                        calendarIdentifier: String?) async throws -> Bool {
        removalStarted = true
        if suspendRemoval {
            await withCheckedContinuation { continuation in
                removalContinuation = continuation
            }
        }
        if let removalError { throw removalError }
        guard records.removeValue(forKey: taskIdentifier) != nil else { return false }
        removalCount += 1
        return true
    }
    func finishRemoval() {
        suspendRemoval = false
        removalContinuation?.resume()
        removalContinuation = nil
    }
    func finishCreation() {
        suspendCreation = false
        creationContinuation?.resume()
        creationContinuation = nil
    }
    func fetchReminderRecords(for requests: [ReminderLookupRequest]) async throws -> ReminderReadSnapshot {
        ReminderReadSnapshot(recordsByTaskIdentifier: records.filter { key, _ in
            requests.contains { $0.taskIdentifier == key }
        }, readableCalendarIdentifiers: ["list"])
    }
}
