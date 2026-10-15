import CoreGraphics
import Foundation
import XCTest

@testable import Notizen

@MainActor
final class TaskDueDateTests: XCTestCase {
    private let firstDate = TaskDueDate(year: 2026, month: 10, day: 25)
    private let secondDate = TaskDueDate(year: 2026, month: 11, day: 2)

    func testLegacyTaskDecodesWithoutDateAndDateSurvivesOCRMerge() throws {
        let task = makeTask()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any]
        )
        object.removeValue(forKey: "dueDate")
        object.removeValue(forKey: "reminderDueDateSyncPending")
        let legacy = try JSONDecoder().decode(
            RecognizedTask.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.dueDate)
        XCTAssertFalse(legacy.reminderDueDateSyncPending)

        var dated = task
        dated.dueDate = firstDate
        let candidate = TaskCandidate(
            bounds: task.bounds, text: "New OCR text", confidence: 0.8, isChecked: false
        )
        let merged = try XCTUnwrap(TaskRecognitionSession.merge([candidate], with: [dated]).first)
        XCTAssertEqual(merged.id, task.id)
        XCTAssertEqual(merged.dueDate, firstDate)
        XCTAssertEqual(try JSONDecoder().decode(
            RecognizedTask.self, from: JSONEncoder().encode(merged)
        ).dueDate, firstDate)

        let missing = try XCTUnwrap(TaskRecognitionSession.merge([], with: [merged]).first)
        XCTAssertFalse(missing.isPresent)
        XCTAssertEqual(missing.dueDate, firstDate)
        let rediscovered = try XCTUnwrap(
            TaskRecognitionSession.merge([candidate], with: [missing]).first
        )
        XCTAssertEqual(rediscovered.id, task.id)
        XCTAssertEqual(rediscovered.dueDate, firstDate)
        XCTAssertTrue(rediscovered.isPresent)
    }

    func testDateOnlyRoundTripsAcrossCalendarBoundary() {
        XCTAssertEqual(TaskDueDate(date: firstDate.date), firstDate)
        XCTAssertEqual(TaskDueDate(date: secondDate.date), secondDate)
        XCTAssertThrowsError(try JSONDecoder().decode(
            TaskDueDate.self, from: Data("{\"year\":2026,\"month\":2,\"day\":30}".utf8)
        ))
    }

    func testTimedDateCodingAndValidation() throws {
        let timed = TaskDueDate(year: 2026, month: 10, day: 2, hour: 16, minute: 30)
        XCTAssertTrue(timed.hasTime)
        XCTAssertEqual(try JSONDecoder().decode(TaskDueDate.self, from: JSONEncoder().encode(timed)), timed)
        XCTAssertEqual(Calendar(identifier: .gregorian).dateComponents(
            [.hour, .minute], from: timed.date
        ).hour, 16)
        XCTAssertEqual(TaskDueDate(date: timed.date), TaskDueDate(year: 2026, month: 10, day: 2))

        let legacy = try JSONDecoder().decode(
            TaskDueDate.self, from: Data("{\"year\":2026,\"month\":10,\"day\":2}".utf8)
        )
        XCTAssertFalse(legacy.hasTime)
        XCTAssertEqual(legacy, TaskDueDate(year: 2026, month: 10, day: 2))
        for json in [
            "{\"year\":2026,\"month\":10,\"day\":2,\"hour\":16}",
            "{\"year\":2026,\"month\":10,\"day\":2,\"minute\":30}",
            "{\"year\":2026,\"month\":10,\"day\":2,\"hour\":24,\"minute\":0}",
            "{\"year\":2026,\"month\":10,\"day\":2,\"hour\":9,\"minute\":60}"
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(TaskDueDate.self, from: Data(json.utf8)))
        }
    }

    func testAlarmFieldsDecodeFromLegacyAndRoundTrip() throws {
        let task = makeTask()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any]
        )
        object.removeValue(forKey: "reminderAlarmOffsetMinutes")
        object.removeValue(forKey: "reminderLastSyncedAlarmOffsetMinutes")
        object.removeValue(forKey: "alarmSyncPending")
        let restored = try JSONDecoder().decode(
            RecognizedTask.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(restored.reminderAlarmOffsetMinutes)
        XCTAssertNil(restored.reminderLastSyncedAlarmOffsetMinutes)
        XCTAssertFalse(restored.alarmSyncPending)

        var updated = task
        updated.reminderAlarmOffsetMinutes = 15
        updated.reminderLastSyncedAlarmOffsetMinutes = 60
        updated.alarmSyncPending = true
        let decoded = try JSONDecoder().decode(RecognizedTask.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(decoded.reminderAlarmOffsetMinutes, 15)
        XCTAssertEqual(decoded.reminderLastSyncedAlarmOffsetMinutes, 60)
        XCTAssertTrue(decoded.alarmSyncPending)
    }

    func testSelectedDatePersistsImmediatelyAndTransfersOnCreate() async throws {
        let store = DueDateReminderStore()
        let (session, _, saved) = makeSession(store: store)
        let taskID = try XCTUnwrap(session.tasks.first?.id)

        session.updateDueDate(firstDate, for: taskID)
        XCTAssertEqual(saved.value.last?.dueDate, firstDate)
        await session.createReminder(for: taskID)
        try await waitUntil { store.records[taskID]?.dueDate == firstDate }

        XCTAssertEqual(store.creationDates, [firstDate])
        XCTAssertEqual(session.tasks.first?.dueDate, firstDate)
        XCTAssertFalse(try XCTUnwrap(session.tasks.first).reminderDueDateSyncPending)
    }

    func testLinkedDateUpdatesAndRemovesFromReminder() async throws {
        let store = DueDateReminderStore()
        let task = makeTask(reminderIdentifier: "r1", dueDate: firstDate)
        store.records[task.id] = record(for: task, dueDate: firstDate)
        let (session, _, saved) = makeSession(store: store, task: task)
        await session.refreshReminderStatuses()

        session.updateDueDate(secondDate, for: task.id)
        XCTAssertEqual(saved.value.last?.dueDate, secondDate)
        try await waitUntil { store.records[task.id]?.dueDate == secondDate }
        try await waitUntil { session.tasks.first?.reminderDueDateSyncPending == false }

        session.updateDueDate(nil, for: task.id)
        XCTAssertNil(saved.value.last?.dueDate)
        try await waitUntil { store.dateUpdates.count >= 2 && store.dateUpdates.last! == nil }
        try await waitUntil { session.tasks.first?.reminderDueDateSyncPending == false }
        XCTAssertNil(store.records[task.id]?.dueDate)
    }

    func testExternalDateReadbackAdoptsDateWithoutWritingItBack() async throws {
        let store = DueDateReminderStore()
        let task = makeTask(reminderIdentifier: "r1")
        store.records[task.id] = record(for: task, dueDate: firstDate)
        let (session, _, saved) = makeSession(store: store, task: task)

        await session.refreshReminderStatuses()
        try await waitUntil { session.tasks.first?.dueDate == firstDate }

        XCTAssertEqual(saved.value.last?.dueDate, firstDate)
        XCTAssertTrue(store.dateUpdates.isEmpty)
    }

    func testExternalDateRemovalClearsLocalDateWithoutWritingBack() async throws {
        let store = DueDateReminderStore()
        let task = makeTask(reminderIdentifier: "r1", dueDate: firstDate)
        store.records[task.id] = record(for: task, dueDate: nil)
        let (session, _, _) = makeSession(store: store, task: task)

        await session.refreshReminderStatuses()
        try await waitUntil { session.tasks.first?.dueDate == nil }

        XCTAssertTrue(store.dateUpdates.isEmpty)
    }

    func testRestoreTransfersSavedDateToReplacementReminder() async throws {
        let store = DueDateReminderStore()
        var task = makeTask(reminderIdentifier: "deleted-reminder", dueDate: firstDate)
        task.reminderStatus = .deleted
        let (session, _, _) = makeSession(store: store, task: task)

        await session.restoreReminder(for: task.id)
        try await waitUntil { store.records[task.id]?.dueDate == firstDate }

        XCTAssertEqual(store.creationDates, [firstDate])
        XCTAssertEqual(session.tasks.first?.reminderStatus, .open)
    }

    func testEditDuringDateWriteSchedulesLatestValue() async throws {
        let store = DueDateReminderStore()
        let task = makeTask(reminderIdentifier: "r1", dueDate: firstDate)
        store.records[task.id] = record(for: task, dueDate: firstDate)
        store.suspendNextDateUpdate = true
        let (session, _, _) = makeSession(store: store, task: task)
        await session.refreshReminderStatuses()

        session.updateDueDate(secondDate, for: task.id)
        try await waitUntil { store.dateUpdateIsSuspended }
        session.updateDueDate(nil, for: task.id)
        store.resumeDateUpdate()
        try await waitUntil { store.records[task.id]?.dueDate == nil }
        try await waitUntil { session.tasks.first?.reminderDueDateSyncPending == false }

        XCTAssertEqual(store.dateUpdates, [secondDate, nil])
        XCTAssertNil(session.tasks.first?.dueDate)
    }

    func testStaleReadbackCannotOverwritePendingLocalDateAfterSaveError() async throws {
        let store = DueDateReminderStore()
        let task = makeTask(reminderIdentifier: "r1", dueDate: firstDate)
        store.records[task.id] = record(for: task, dueDate: firstDate)
        store.suspendNextFetch = true
        store.dateUpdateError = ReminderServiceError.saveFailed("offline")
        let (session, _, saved) = makeSession(store: store, task: task)
        try await waitUntil { store.fetchIsSuspended }

        session.updateDueDate(secondDate, for: task.id)
        store.resumeFetch()
        try await waitUntil { session.tasks.first?.reminderSyncError != nil }
        XCTAssertEqual(session.tasks.first?.dueDate, secondDate)
        XCTAssertEqual(saved.value.last?.dueDate, secondDate)
        XCTAssertTrue(try XCTUnwrap(session.tasks.first).reminderDueDateSyncPending)

        store.dateUpdateError = nil
        try await waitUntil { !session.isSyncingReminders }
        session.retryReminderSync()
        try await waitUntil { store.records[task.id]?.dueDate == secondDate }
        try await waitUntil { session.tasks.first?.reminderDueDateSyncPending == false }
    }

    func testDateFailureDoesNotRepeatAlreadySavedCompletion() async throws {
        let store = DueDateReminderStore()
        var task = makeTask(reminderIdentifier: "r1", dueDate: firstDate)
        task.isChecked = true
        store.records[task.id] = record(for: task, dueDate: firstDate)
        store.dateUpdateError = ReminderServiceError.saveFailed("offline")
        store.suspendNextFetch = true
        let (session, _, _) = makeSession(store: store, task: task)
        try await waitUntil { store.fetchIsSuspended }

        session.updateDueDate(secondDate, for: task.id)
        store.resumeFetch()
        try await waitUntil { session.tasks.first?.reminderSyncError != nil }
        try await waitUntil { !session.isSyncingReminders }
        XCTAssertEqual(store.completionUpdates, [true])
        XCTAssertEqual(session.tasks.first?.reminderLastSyncedIsChecked, true)

        store.dateUpdateError = nil
        session.retryReminderSync()
        try await waitUntil { store.records[task.id]?.dueDate == secondDate }
        XCTAssertEqual(store.completionUpdates, [true])
    }

    func testTimedDueDateAndAlarmSyncThroughSession() async throws {
        let store = DueDateReminderStore()
        let task = makeTask(reminderIdentifier: "r1", dueDate: firstDate)
        store.records[task.id] = record(for: task, dueDate: firstDate)
        let (session, _, _) = makeSession(store: store, task: task)
        await session.refreshReminderStatuses()

        let timed = TaskDueDate(year: 2026, month: 10, day: 25, hour: 16, minute: 30)
        session.updateDueDate(timed, for: task.id, alarmOffsetMinutes: 15)
        try await waitUntil { store.records[task.id]?.dueDate == timed
            && store.records[task.id]?.alarmOffsetMinutes == 15 }
        try await waitUntil { session.tasks.first?.alarmSyncPending == false }
        XCTAssertEqual(session.tasks.first?.reminderLastSyncedAlarmOffsetMinutes, 15)

        session.updateDueDate(timed, for: task.id, alarmOffsetMinutes: nil)
        try await waitUntil { store.records[task.id]?.alarmOffsetMinutes == nil }
        try await waitUntil { session.tasks.first?.alarmSyncPending == false }
        XCTAssertEqual(store.scheduleUpdates.map(\.1), [15, nil])
    }

    private func makeTask(
        reminderIdentifier: String? = nil,
        dueDate: TaskDueDate? = nil
    ) -> RecognizedTask {
        RecognizedTask(
            id: UUID(), bounds: CGRect(x: 20, y: 20, width: 40, height: 30),
            recognizedText: "Aufgabe", correctedText: nil,
            confidence: 0.9, isChecked: false,
            reminderIdentifier: reminderIdentifier,
            reminderCalendarIdentifier: reminderIdentifier == nil ? nil : "list-1",
            reminderStatus: reminderIdentifier == nil ? nil : .open,
            reminderLastSyncedIsChecked: reminderIdentifier == nil ? nil : false,
            dueDate: dueDate
        )
    }

    private func record(for task: RecognizedTask, dueDate: TaskDueDate?) -> ReminderRecord {
        ReminderRecord(
            taskIdentifier: task.id,
            reminderIdentifier: task.reminderIdentifier ?? "r1",
            calendarIdentifier: "list-1", isCompleted: false, dueDate: dueDate
        )
    }

    private func makeSession(
        store: DueDateReminderStore,
        task: RecognizedTask? = nil
    ) -> (TaskRecognitionSession, ReminderService, SavedTasksBox) {
        let defaults = UserDefaults(suiteName: "TaskDueDateTests-\(UUID().uuidString)")!
        let service = ReminderService(store: store, userDefaults: defaults)
        let session = TaskRecognitionSession()
        let saved = SavedTasksBox()
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task ?? makeTask()]) { tasks, _ in
            saved.value = tasks
        }
        return (session, service, saved)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for reminder date operation")
    }
}

@MainActor
private final class SavedTasksBox {
    var value: [RecognizedTask] = []
}

@MainActor
private final class DueDateReminderStore: ReminderStore {
    var records: [UUID: ReminderRecord] = [:]
    var creationDates: [TaskDueDate?] = []
    var dateUpdates: [TaskDueDate?] = []
    var completionUpdates: [Bool] = []
    var scheduleUpdates: [(TaskDueDate?, Int?)] = []
    var dateUpdateError: Error?
    var suspendNextFetch = false
    var fetchIsSuspended = false
    var suspendNextDateUpdate = false
    var dateUpdateIsSuspended = false
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var dateUpdateContinuation: CheckedContinuation<Void, Never>?

    func authorizationStatus() -> ReminderAuthorization { .fullAccess }
    func requestFullAccess() async throws -> Bool { true }
    func writableLists() -> [ReminderList] {
        [ReminderList(id: "list-1", title: "Notizen", sourceTitle: "iCloud")]
    }
    func defaultListIdentifier() -> String? { "list-1" }

    func createReminder(
        title: String, isCompleted: Bool, listIdentifier: String, taskIdentifier: UUID
    ) async throws -> String {
        try await createReminder(
            title: title, isCompleted: isCompleted, dueDate: nil,
            listIdentifier: listIdentifier, taskIdentifier: taskIdentifier
        )
    }

    func createReminder(
        title: String, isCompleted: Bool, dueDate: TaskDueDate?,
        listIdentifier: String, taskIdentifier: UUID
    ) async throws -> String {
        try await createReminder(
            title: title, isCompleted: isCompleted, dueDate: dueDate,
            alarmOffsetMinutes: nil, listIdentifier: listIdentifier,
            taskIdentifier: taskIdentifier
        )
    }

    func createReminder(
        title: String, isCompleted: Bool, dueDate: TaskDueDate?,
        alarmOffsetMinutes: Int?, listIdentifier: String, taskIdentifier: UUID
    ) async throws -> String {
        creationDates.append(dueDate)
        let identifier = "r-\(taskIdentifier.uuidString)"
        records[taskIdentifier] = ReminderRecord(
            taskIdentifier: taskIdentifier, reminderIdentifier: identifier,
            calendarIdentifier: listIdentifier, isCompleted: isCompleted, dueDate: dueDate,
            alarmOffsetMinutes: alarmOffsetMinutes
        )
        return identifier
    }

    func setReminderCompleted(identifier: String, isCompleted: Bool) async throws {
        completionUpdates.append(isCompleted)
        guard let taskID = records.first(where: { $0.value.reminderIdentifier == identifier })?.key,
              let existing = records[taskID] else { return }
        records[taskID] = ReminderRecord(
            taskIdentifier: taskID, reminderIdentifier: identifier,
            calendarIdentifier: existing.calendarIdentifier,
            isCompleted: isCompleted, dueDate: existing.dueDate
        )
    }

    func setReminderDueDate(identifier: String, dueDate: TaskDueDate?) async throws {
        dateUpdates.append(dueDate)
        if suspendNextDateUpdate {
            suspendNextDateUpdate = false
            dateUpdateIsSuspended = true
            await withCheckedContinuation { continuation in
                dateUpdateContinuation = continuation
            }
            dateUpdateIsSuspended = false
        }
        if let dateUpdateError { throw dateUpdateError }
        guard let taskID = records.first(where: { $0.value.reminderIdentifier == identifier })?.key,
              let existing = records[taskID] else { return }
        records[taskID] = ReminderRecord(
            taskIdentifier: taskID, reminderIdentifier: identifier,
            calendarIdentifier: existing.calendarIdentifier,
            isCompleted: existing.isCompleted, dueDate: dueDate,
            alarmOffsetMinutes: existing.alarmOffsetMinutes
        )
    }

    func setReminderSchedule(
        identifier: String, dueDate: TaskDueDate?, alarmOffsetMinutes: Int?,
        previousAlarmOffsetMinutes: Int?
    ) async throws {
        scheduleUpdates.append((dueDate, alarmOffsetMinutes))
        try await setReminderDueDate(identifier: identifier, dueDate: dueDate)
        guard let taskID = records.first(where: { $0.value.reminderIdentifier == identifier })?.key,
              let existing = records[taskID] else { return }
        records[taskID] = ReminderRecord(
            taskIdentifier: taskID, reminderIdentifier: identifier,
            calendarIdentifier: existing.calendarIdentifier,
            isCompleted: existing.isCompleted, dueDate: dueDate,
            alarmOffsetMinutes: alarmOffsetMinutes
        )
    }

    func fetchReminderRecords(
        for requests: [ReminderLookupRequest]
    ) async throws -> ReminderReadSnapshot {
        let snapshot = ReminderReadSnapshot(
            recordsByTaskIdentifier: records,
            readableCalendarIdentifiers: ["list-1"]
        )
        if suspendNextFetch {
            suspendNextFetch = false
            fetchIsSuspended = true
            await withCheckedContinuation { continuation in
                fetchContinuation = continuation
            }
            fetchIsSuspended = false
        }
        return snapshot
    }

    func resumeFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }

    func resumeDateUpdate() {
        dateUpdateContinuation?.resume()
        dateUpdateContinuation = nil
    }
}
