import CoreGraphics
import Foundation
import XCTest

@testable import Notizen

@MainActor
final class ReminderSessionTests: XCTestCase {
    func testLegacyRecognizedTaskDecodingUsesReminderDefaults() throws {
        let original = makeTask()
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "reminderIdentifier")
        object.removeValue(forKey: "isPresent")
        object.removeValue(forKey: "reminderSyncError")
        object.removeValue(forKey: "reminderLastSyncedIsChecked")

        let decoded = try JSONDecoder().decode(
            RecognizedTask.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.reminderIdentifier)
        XCTAssertTrue(decoded.isPresent)
        XCTAssertNil(decoded.reminderSyncError)
        XCTAssertNil(decoded.reminderLastSyncedIsChecked)
    }

    func testLinkedTaskMissingFromOCRIsRetainedAsAbsent() {
        let linked = makeTask(reminderIdentifier: "reminder-1")

        let merged = TaskRecognitionSession.merge([], with: [linked])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, linked.id)
        XCTAssertEqual(merged[0].reminderIdentifier, "reminder-1")
        XCTAssertFalse(merged[0].isPresent)
    }

    func testReopeningUnchangedLinkedTaskDoesNotOverwriteReminderCompletion() async {
        let store = MockReminderStore()
        let service = makeService(store: store)
        let session = TaskRecognitionSession()
        let saved = makeTask(
            isChecked: false,
            reminderIdentifier: "reminder-1",
            reminderLastSyncedIsChecked: false
        )
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [saved]) { _, _ in }

        session.retryReminderSync()
        await Task.yield()

        XCTAssertTrue(store.completionUpdates.isEmpty)
        XCTAssertFalse(session.isSyncingReminders)
    }

    func testChangedHandwrittenCheckboxUpdatesLinkedReminder() async throws {
        let store = MockReminderStore()
        let service = makeService(store: store)
        let bounds = CGRect(x: 20, y: 30, width: 32, height: 32)
        let saved = makeTask(
            bounds: bounds,
            isChecked: false,
            reminderIdentifier: "reminder-1",
            reminderLastSyncedIsChecked: false
        )
        let session = TaskRecognitionSession(debounceDuration: .zero) { _ in
            [TaskCandidate(bounds: bounds, text: "Ignored linked title", confidence: 0.9, isChecked: true)]
        }
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [saved]) { _, _ in }

        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil {
            store.completionUpdates.count == 1
                && session.tasks.first?.reminderLastSyncedIsChecked == true
        }

        XCTAssertEqual(store.completionUpdates.first?.identifier, "reminder-1")
        XCTAssertEqual(store.completionUpdates.first?.isCompleted, true)
        XCTAssertEqual(session.tasks.first?.reminderLastSyncedIsChecked, true)
    }

    func testRepeatedCreateWhileInFlightCreatesOnlyOneReminder() async throws {
        let store = MockReminderStore()
        store.suspendCreation = true
        let service = makeService(store: store)
        let task = makeTask()
        let session = TaskRecognitionSession()
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }

        let first = Task { await session.createReminder(for: task.id) }
        try await waitUntil { store.createCalls == 1 }
        let second = Task { await session.createReminder(for: task.id) }
        await Task.yield()

        XCTAssertEqual(store.createCalls, 1)
        store.finishCreation()
        await first.value
        await second.value

        XCTAssertEqual(store.createCalls, 1)
        XCTAssertEqual(session.tasks.first?.reminderIdentifier, store.createdIdentifier)
    }

    func testDeactivatePreventsLateCreateFromPersistingIntoAnotherNote() async throws {
        let store = MockReminderStore()
        store.suspendCreation = true
        let service = makeService(store: store)
        let originalTask = makeTask()
        let session = TaskRecognitionSession()
        var firstNoteSaveCount = 0
        var secondNoteSaveCount = 0
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [originalTask]) { _, _ in
            firstNoteSaveCount += 1
        }

        let create = Task { await session.createReminder(for: originalTask.id) }
        try await waitUntil { store.createCalls == 1 }
        session.deactivate()
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in
            secondNoteSaveCount += 1
        }
        store.finishCreation()
        await create.value

        XCTAssertEqual(firstNoteSaveCount, 0)
        XCTAssertEqual(secondNoteSaveCount, 0)
        XCTAssertTrue(session.tasks.isEmpty)
    }

    func testRestoreRechecksLiveStatusAndReusesRecoveredReminder() async throws {
        let store = MockReminderStore()
        store.lists.append(
            ReminderList(id: "original-list", title: "Privat", sourceTitle: "iCloud")
        )
        let service = makeService(store: store)
        let task = makeTask(
            reminderIdentifier: "deleted-reminder",
            reminderCalendarIdentifier: "original-list",
            reminderStatus: .deleted,
            reminderLastSyncedIsChecked: false
        )
        let session = TaskRecognitionSession()
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }
        try await waitUntil { store.fetchCalls >= 1 }

        store.snapshot = ReminderReadSnapshot(
            recordsByTaskIdentifier: [
                task.id: ReminderRecord(
                    taskIdentifier: task.id,
                    reminderIdentifier: "recovered-reminder",
                    calendarIdentifier: "original-list",
                    isCompleted: true
                )
            ],
            readableCalendarIdentifiers: ["list-1", "original-list"]
        )

        await session.restoreReminder(for: task.id)

        XCTAssertEqual(store.createCalls, 0)
        XCTAssertGreaterThanOrEqual(store.fetchCalls, 2)
        XCTAssertEqual(session.tasks.first?.reminderIdentifier, "recovered-reminder")
        XCTAssertEqual(session.tasks.first?.reminderCalendarIdentifier, "original-list")
        XCTAssertEqual(session.tasks.first?.reminderStatus, .completed)
    }

    func testRepeatedRestoreCreatesOnceInOriginalListAndReplacesDeletedLink() async throws {
        let store = MockReminderStore()
        store.lists.append(
            ReminderList(id: "original-list", title: "Privat", sourceTitle: "iCloud")
        )
        store.snapshot = ReminderReadSnapshot(
            recordsByTaskIdentifier: [:],
            readableCalendarIdentifiers: ["list-1", "original-list"]
        )
        store.suspendCreation = true
        let service = makeService(store: store)
        let task = makeTask(
            isChecked: true,
            reminderIdentifier: "deleted-reminder",
            reminderCalendarIdentifier: "original-list",
            reminderStatus: .deleted,
            reminderLastSyncedIsChecked: false
        )
        let session = TaskRecognitionSession()
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }
        try await waitUntil { store.fetchCalls >= 1 }

        let first = Task { await session.restoreReminder(for: task.id) }
        try await waitUntil { store.createCalls == 1 }
        let second = Task { await session.restoreReminder(for: task.id) }
        await Task.yield()

        XCTAssertEqual(store.createCalls, 1)
        XCTAssertEqual(session.tasks.first?.reminderIdentifier, "deleted-reminder")
        store.finishCreation()
        await first.value
        await second.value
        try await waitUntil { store.dateUpdates.count == 1 }

        XCTAssertEqual(store.createCalls, 1)
        XCTAssertEqual(store.creationListIdentifiers, ["original-list"])
        XCTAssertEqual(store.dateUpdates.first?.identifier, store.createdIdentifier)
        XCTAssertNil(store.dateUpdates.first?.dueDate)
        XCTAssertEqual(session.tasks.first?.reminderIdentifier, store.createdIdentifier)
        XCTAssertEqual(session.tasks.first?.reminderStatus, .completed)
        XCTAssertNil(session.tasks.first?.reminderSyncError)
    }

    func testFailedRestoreRetainsDeletedLinkForRetry() async throws {
        let store = MockReminderStore()
        store.snapshot = ReminderReadSnapshot(
            recordsByTaskIdentifier: [:],
            readableCalendarIdentifiers: ["list-1"]
        )
        store.createError = ReminderServiceError.saveFailed("Testfehler")
        let service = makeService(store: store)
        let task = makeTask(
            reminderIdentifier: "deleted-reminder",
            reminderCalendarIdentifier: "list-1",
            reminderStatus: .deleted,
            reminderLastSyncedIsChecked: false
        )
        let session = TaskRecognitionSession()
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }
        try await waitUntil { store.fetchCalls >= 1 }

        await session.restoreReminder(for: task.id)

        XCTAssertEqual(store.createCalls, 1)
        XCTAssertEqual(session.tasks.first?.reminderIdentifier, "deleted-reminder")
        XCTAssertEqual(session.tasks.first?.reminderCalendarIdentifier, "list-1")
        XCTAssertEqual(session.tasks.first?.reminderStatus, .deleted)
        XCTAssertNotNil(session.tasks.first?.reminderSyncError)
        XCTAssertEqual(session.reminderErrorMessage, session.tasks.first?.reminderSyncError)
    }

    func testRestoreDoesNotRecreateWhenOriginalListWasNotReadable() async throws {
        let store = MockReminderStore()
        store.lists.append(
            ReminderList(id: "original-list", title: "Privat", sourceTitle: "iCloud")
        )
        store.snapshot = ReminderReadSnapshot(
            recordsByTaskIdentifier: [:],
            readableCalendarIdentifiers: ["list-1"]
        )
        let service = makeService(store: store)
        let task = makeTask(
            reminderIdentifier: "deleted-reminder",
            reminderCalendarIdentifier: "original-list",
            reminderStatus: .deleted,
            reminderLastSyncedIsChecked: false
        )
        let session = TaskRecognitionSession()
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }
        try await waitUntil { store.fetchCalls >= 1 }

        await session.restoreReminder(for: task.id)

        XCTAssertEqual(store.createCalls, 0)
        XCTAssertEqual(session.tasks.first?.reminderIdentifier, "deleted-reminder")
        XCTAssertEqual(session.tasks.first?.reminderStatus, .deleted)
        XCTAssertEqual(
            session.tasks.first?.reminderSyncError,
            ReminderServiceError.originalListUnavailable.localizedDescription
        )
    }

    func testRestoreDoesNotFallBackWhenOriginalListIsNoLongerWritable() async throws {
        let store = MockReminderStore()
        store.snapshot = ReminderReadSnapshot(
            recordsByTaskIdentifier: [:],
            readableCalendarIdentifiers: ["list-1", "original-list"]
        )
        let service = makeService(store: store)
        let task = makeTask(
            reminderIdentifier: "deleted-reminder",
            reminderCalendarIdentifier: "original-list",
            reminderStatus: .deleted,
            reminderLastSyncedIsChecked: false
        )
        let session = TaskRecognitionSession()
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }
        try await waitUntil { store.fetchCalls >= 1 }

        await session.restoreReminder(for: task.id)

        XCTAssertEqual(store.createCalls, 0)
        XCTAssertEqual(session.tasks.first?.reminderIdentifier, "deleted-reminder")
        XCTAssertEqual(session.tasks.first?.reminderStatus, .deleted)
        XCTAssertEqual(
            session.tasks.first?.reminderSyncError,
            ReminderServiceError.originalListUnavailable.localizedDescription
        )
    }

    private func makeService(store: MockReminderStore) -> ReminderService {
        let suiteName = "ReminderSessionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ReminderService(store: store, userDefaults: defaults)
    }

    private func makeTask(
        bounds: CGRect = CGRect(x: 20, y: 30, width: 32, height: 32),
        isChecked: Bool = false,
        reminderIdentifier: String? = nil,
        reminderCalendarIdentifier: String? = nil,
        reminderStatus: TaskReminderStatus? = nil,
        reminderLastSyncedIsChecked: Bool? = nil
    ) -> RecognizedTask {
        RecognizedTask(
            id: UUID(),
            bounds: bounds,
            recognizedText: "Milch kaufen",
            correctedText: nil,
            confidence: 0.9,
            isChecked: isChecked,
            reminderIdentifier: reminderIdentifier,
            reminderCalendarIdentifier: reminderCalendarIdentifier,
            reminderStatus: reminderStatus,
            reminderLastSyncedIsChecked: reminderLastSyncedIsChecked
        )
    }

    private func waitUntil(
        attempts: Int = 100,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous reminder operation")
    }
}

@MainActor
private final class MockReminderStore: ReminderStore {
    struct CompletionUpdate: Equatable {
        let identifier: String
        let isCompleted: Bool
    }

    struct DateUpdate: Equatable {
        let identifier: String
        let dueDate: TaskDueDate?
    }

    var authorization: ReminderAuthorization = .fullAccess
    var lists = [ReminderList(id: "list-1", title: "Notizen", sourceTitle: "iCloud")]
    var createCalls = 0
    var creationListIdentifiers: [String] = []
    var completionUpdates: [CompletionUpdate] = []
    var dateUpdates: [DateUpdate] = []
    var suspendCreation = false
    var createError: Error?
    var fetchCalls = 0
    var snapshot = ReminderReadSnapshot(
        recordsByTaskIdentifier: [:],
        readableCalendarIdentifiers: ["list-1"]
    )
    let createdIdentifier = "created-reminder"

    private var creationContinuation: CheckedContinuation<Void, Never>?

    func authorizationStatus() -> ReminderAuthorization { authorization }

    func requestFullAccess() async throws -> Bool {
        authorization = .fullAccess
        return true
    }

    func writableLists() -> [ReminderList] { lists }

    func defaultListIdentifier() -> String? { lists.first?.id }

    func createReminder(
        title: String,
        isCompleted: Bool,
        listIdentifier: String,
        taskIdentifier: UUID
    ) async throws -> String {
        createCalls += 1
        creationListIdentifiers.append(listIdentifier)
        if suspendCreation {
            await withCheckedContinuation { continuation in
                creationContinuation = continuation
            }
        }
        if let createError { throw createError }
        // A successful save must also be visible to the session's immediate
        // status readback, otherwise the mock reports the new reminder deleted.
        var records = snapshot.recordsByTaskIdentifier
        records[taskIdentifier] = ReminderRecord(
            taskIdentifier: taskIdentifier,
            reminderIdentifier: createdIdentifier,
            calendarIdentifier: listIdentifier,
            isCompleted: isCompleted
        )
        snapshot = ReminderReadSnapshot(
            recordsByTaskIdentifier: records,
            readableCalendarIdentifiers: snapshot.readableCalendarIdentifiers.union([listIdentifier])
        )
        return createdIdentifier
    }

    func setReminderCompleted(identifier: String, isCompleted: Bool) async throws {
        completionUpdates.append(
            CompletionUpdate(identifier: identifier, isCompleted: isCompleted)
        )
    }

    func setReminderDueDate(identifier: String, dueDate: TaskDueDate?) async throws {
        dateUpdates.append(DateUpdate(identifier: identifier, dueDate: dueDate))
        var records = snapshot.recordsByTaskIdentifier
        guard let (taskID, record) = records.first(where: {
            $0.value.reminderIdentifier == identifier
        }) else { return }
        records[taskID] = ReminderRecord(
            taskIdentifier: taskID, reminderIdentifier: identifier,
            calendarIdentifier: record.calendarIdentifier,
            isCompleted: record.isCompleted, dueDate: dueDate
        )
        snapshot = ReminderReadSnapshot(
            recordsByTaskIdentifier: records,
            readableCalendarIdentifiers: snapshot.readableCalendarIdentifiers
        )
    }

    func fetchReminderRecords(
        for requests: [ReminderLookupRequest]
    ) async throws -> ReminderReadSnapshot {
        fetchCalls += 1
        return snapshot
    }

    func finishCreation() {
        suspendCreation = false
        creationContinuation?.resume()
        creationContinuation = nil
    }
}
