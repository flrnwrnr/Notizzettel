import CoreGraphics
import Foundation
import XCTest

@testable import Notizen

@MainActor
final class ReminderStatusTests: XCTestCase {
    func testMarkerStateUsesConfirmedReminderStateInsteadOfUnsyncedHandwriting() {
        XCTAssertEqual(makeTask(reminderIdentifier: nil).markerState, .proposal)
        XCTAssertEqual(
            makeTask(isChecked: true, reminderIdentifier: "r", reminderStatus: .open).markerState,
            .open
        )
        XCTAssertEqual(
            makeTask(isChecked: false, reminderIdentifier: "r", reminderStatus: .completed).markerState,
            .completed
        )
        XCTAssertEqual(
            makeTask(reminderIdentifier: "r", reminderStatus: .deleted).markerState,
            .deleted
        )
        XCTAssertEqual(
            makeTask(
                reminderIdentifier: "r",
                reminderLastSyncedIsChecked: true
            ).markerState,
            .completed
        )
    }

    func testExternalCompletionReadbackDoesNotChangeHandwritingOrSyncBaseline() async throws {
        let task = makeTask(
            isChecked: false,
            reminderIdentifier: "r1",
            calendarIdentifier: "calendar-1",
            reminderStatus: .open,
            reminderLastSyncedIsChecked: false
        )
        let store = ReminderStatusStoreMock()
        store.snapshot = snapshot(task: task, identifier: "r1", completed: true)
        let (session, defaults, suiteName) = makeSession(task: task, store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await session.refreshReminderStatuses()
        try await waitUntil { session.tasks.first?.reminderStatus == .completed }

        XCTAssertFalse(try XCTUnwrap(session.tasks.first).isChecked)
        XCTAssertEqual(session.tasks.first?.reminderLastSyncedIsChecked, false)
        XCTAssertEqual(session.tasks.first?.markerState, .completed)
        XCTAssertTrue(store.completionUpdates.isEmpty)
    }

    func testMissingReminderIsDeletedOnlyWhenOwningCalendarWasRead() async throws {
        let task = makeTask(
            reminderIdentifier: "missing",
            calendarIdentifier: "calendar-1",
            reminderStatus: .open,
            reminderLastSyncedIsChecked: false
        )
        let store = ReminderStatusStoreMock()
        store.snapshot = ReminderReadSnapshot(
            recordsByTaskIdentifier: [:],
            readableCalendarIdentifiers: ["calendar-1"]
        )
        let (session, defaults, suiteName) = makeSession(task: task, store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await session.refreshReminderStatuses()
        try await waitUntil { session.tasks.first?.reminderStatus == .deleted }

        XCTAssertEqual(session.tasks.first?.reminderIdentifier, "missing")
        XCTAssertEqual(session.tasks.first?.markerState, .deleted)
    }

    func testRemovedCalendarAndFailedReadDoNotCreateFalseDeletion() async throws {
        let task = makeTask(
            reminderIdentifier: "r1",
            calendarIdentifier: "removed-calendar",
            reminderStatus: .completed,
            reminderLastSyncedIsChecked: false
        )
        let store = ReminderStatusStoreMock()
        store.snapshot = ReminderReadSnapshot(
            recordsByTaskIdentifier: [:],
            readableCalendarIdentifiers: ["another-calendar"]
        )
        let (session, defaults, suiteName) = makeSession(task: task, store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await session.refreshReminderStatuses()
        try await waitUntil { session.reminderErrorMessage != nil }
        XCTAssertEqual(session.tasks.first?.reminderStatus, .completed)

        store.error = ReminderServiceError.fetchFailed
        await session.refreshReminderStatuses()
        XCTAssertEqual(session.tasks.first?.reminderStatus, .completed)

        store.authorization = .denied
        await session.refreshReminderStatuses()
        XCTAssertEqual(session.tasks.first?.reminderStatus, .completed)
    }

    func testStableMarkerRecoveryUpdatesIdentifierAndRestoresDeletedTask() async throws {
        let task = makeTask(
            reminderIdentifier: "old-id",
            calendarIdentifier: "calendar-1",
            reminderStatus: .deleted,
            reminderLastSyncedIsChecked: false
        )
        let store = ReminderStatusStoreMock()
        store.snapshot = snapshot(task: task, identifier: "new-id", completed: false)
        let (session, defaults, suiteName) = makeSession(task: task, store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await session.refreshReminderStatuses()
        try await waitUntil { session.tasks.first?.reminderIdentifier == "new-id" }

        XCTAssertEqual(session.tasks.first?.reminderStatus, .open)
        XCTAssertEqual(session.tasks.first?.reminderCalendarIdentifier, "calendar-1")
    }

    func testDeletedTombstoneIsNeitherRecreatedNorCompletionSynced() async throws {
        let bounds = CGRect(x: 20, y: 20, width: 32, height: 32)
        let task = makeTask(
            bounds: bounds,
            reminderIdentifier: "deleted-id",
            calendarIdentifier: "calendar-1",
            reminderStatus: .deleted,
            reminderLastSyncedIsChecked: false
        )
        let store = ReminderStatusStoreMock()
        store.snapshot = ReminderReadSnapshot(
            recordsByTaskIdentifier: [:],
            readableCalendarIdentifiers: ["calendar-1"]
        )
        let (service, defaults, suiteName) = makeService(store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        service.setAutomaticCreation(true)
        let session = TaskRecognitionSession(
            debounceDuration: .zero,
            autoCreationDelay: .zero
        ) { _ in
            [TaskCandidate(bounds: bounds, text: "Aufgabe", confidence: 0.9, isChecked: true)]
        }
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }

        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil { session.tasks.first?.isChecked == true }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.createCalls, 0)
        XCTAssertTrue(store.completionUpdates.isEmpty)
        XCTAssertEqual(session.tasks.first?.reminderStatus, .deleted)
    }

    func testLegacyLinkedTaskDecodesWithoutOwnerOrStatus() throws {
        let task = makeTask(
            reminderIdentifier: "legacy-id",
            reminderLastSyncedIsChecked: false
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any]
        )
        object.removeValue(forKey: "reminderCalendarIdentifier")
        object.removeValue(forKey: "reminderStatus")

        let decoded = try JSONDecoder().decode(
            RecognizedTask.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.reminderCalendarIdentifier)
        XCTAssertNil(decoded.reminderStatus)
        XCTAssertEqual(decoded.markerState, .open)
    }

    private func makeSession(
        task: RecognizedTask,
        store: ReminderStatusStoreMock
    ) -> (TaskRecognitionSession, UserDefaults, String) {
        let (service, defaults, suiteName) = makeService(store: store)
        let session = TaskRecognitionSession()
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }
        return (session, defaults, suiteName)
    }

    private func makeService(
        store: ReminderStatusStoreMock
    ) -> (ReminderService, UserDefaults, String) {
        let suiteName = "ReminderStatusTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (ReminderService(store: store, userDefaults: defaults), defaults, suiteName)
    }

    private func snapshot(
        task: RecognizedTask,
        identifier: String,
        completed: Bool
    ) -> ReminderReadSnapshot {
        ReminderReadSnapshot(
            recordsByTaskIdentifier: [
                task.id: ReminderRecord(
                    taskIdentifier: task.id,
                    reminderIdentifier: identifier,
                    calendarIdentifier: "calendar-1",
                    isCompleted: completed
                )
            ],
            readableCalendarIdentifiers: ["calendar-1"]
        )
    }

    private func makeTask(
        bounds: CGRect = CGRect(x: 20, y: 20, width: 32, height: 32),
        isChecked: Bool = false,
        reminderIdentifier: String?,
        calendarIdentifier: String? = nil,
        reminderStatus: TaskReminderStatus? = nil,
        reminderLastSyncedIsChecked: Bool? = nil
    ) -> RecognizedTask {
        RecognizedTask(
            id: UUID(),
            bounds: bounds,
            recognizedText: "Aufgabe",
            correctedText: nil,
            confidence: 0.9,
            isChecked: isChecked,
            reminderIdentifier: reminderIdentifier,
            reminderCalendarIdentifier: calendarIdentifier,
            reminderStatus: reminderStatus,
            reminderLastSyncedIsChecked: reminderLastSyncedIsChecked
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for reminder status")
    }
}

@MainActor
private final class ReminderStatusStoreMock: ReminderStore {
    struct CompletionUpdate: Equatable {
        let identifier: String
        let isCompleted: Bool
    }

    var authorization: ReminderAuthorization = .fullAccess
    var lists = [ReminderList(id: "calendar-1", title: "Notizen", sourceTitle: "iCloud")]
    var snapshot = ReminderReadSnapshot(
        recordsByTaskIdentifier: [:],
        readableCalendarIdentifiers: ["calendar-1"]
    )
    var error: Error?
    var createCalls = 0
    var completionUpdates: [CompletionUpdate] = []

    func authorizationStatus() -> ReminderAuthorization { authorization }

    func requestFullAccess() async throws -> Bool { authorization == .fullAccess }

    func writableLists() -> [ReminderList] { lists }

    func defaultListIdentifier() -> String? { lists.first?.id }

    func createReminder(
        title: String,
        isCompleted: Bool,
        listIdentifier: String,
        taskIdentifier: UUID
    ) async throws -> String {
        createCalls += 1
        return "created-\(taskIdentifier.uuidString)"
    }

    func setReminderCompleted(identifier: String, isCompleted: Bool) async throws {
        completionUpdates.append(
            CompletionUpdate(identifier: identifier, isCompleted: isCompleted)
        )
    }

    func fetchReminderRecords(
        for requests: [ReminderLookupRequest]
    ) async throws -> ReminderReadSnapshot {
        if let error { throw error }
        return snapshot
    }
}
