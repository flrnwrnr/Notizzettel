@preconcurrency import EventKit
import Foundation
import XCTest

@testable import Notizen

@MainActor
final class EventKitIntegrationTests: XCTestCase {
    func testRealStoreDeduplicatesAndSynchronizesCompletionWithoutFallingBack() async throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("The EventKit integration test is intentionally simulator-only.")
#endif

        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw XCTSkip("The simulator has not granted full Reminders access to the test host.")
        }

        let eventStore = EKEventStore()
        guard let localSource = eventStore.sources.first(where: { $0.sourceType == .local }) else {
            throw XCTSkip("The simulator has no local EventKit source for a temporary reminder list.")
        }

        let suiteName = "EventKitIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = "Notizen Integration \(UUID().uuidString)"
        calendar.source = localSource
        try eventStore.saveCalendar(calendar, commit: true)
        let calendarID = calendar.calendarIdentifier

        defer {
            if let remainingCalendar = eventStore.calendar(withIdentifier: calendarID) {
                try? eventStore.removeCalendar(remainingCalendar, commit: true)
            }
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(calendar.allowsContentModifications)

        let service = ReminderService(
            store: EventKitReminderStore(eventStore: eventStore),
            userDefaults: defaults
        )
        service.refresh()
        let exposedList = try XCTUnwrap(service.lists.first(where: { $0.id == calendarID }))
        XCTAssertEqual(exposedList.title, calendar.title)
        XCTAssertEqual(exposedList.sourceTitle, localSource.title)
        service.selectList(calendarID)
        XCTAssertEqual(service.selectedListID, calendarID)

        let taskID = UUID()
        let title = "Notizen integration \(taskID.uuidString)"
        let initialDueDate = TaskDueDate(year: 2026, month: 10, day: 25)
        let updatedDueDate = TaskDueDate(year: 2026, month: 11, day: 2)
        let firstIdentifier = try await service.createReminder(
            title: title,
            isCompleted: false,
            taskID: taskID,
            dueDate: initialDueDate
        )
        let duplicateIdentifier = try await service.createReminder(
            title: title,
            isCompleted: false,
            taskID: taskID
        )

        XCTAssertEqual(duplicateIdentifier, firstIdentifier)
        var created = try await reminders(in: [calendar], eventStore: eventStore)
            .filter { $0.title == title }
        XCTAssertEqual(created.count, 1)
        XCTAssertFalse(try XCTUnwrap(created.first).isCompleted)
        XCTAssertEqual(try XCTUnwrap(created.first).dueDateComponents?.day, initialDueDate.day)

        var snapshot = try await service.fetchReminderRecords(for: [
            ReminderLookupRequest(
                taskIdentifier: taskID,
                reminderIdentifier: firstIdentifier,
                calendarIdentifier: calendarID
            )
        ])
        var record = try XCTUnwrap(snapshot.recordsByTaskIdentifier[taskID])
        XCTAssertEqual(record.reminderIdentifier, firstIdentifier)
        XCTAssertEqual(record.calendarIdentifier, calendarID)
        XCTAssertFalse(record.isCompleted)
        XCTAssertEqual(record.dueDate, initialDueDate)
        XCTAssertTrue(snapshot.readableCalendarIdentifiers.contains(calendarID))

        try await service.updateReminderDueDate(identifier: firstIdentifier, dueDate: updatedDueDate)
        snapshot = try await service.fetchReminderRecords(for: [
            ReminderLookupRequest(
                taskIdentifier: taskID,
                reminderIdentifier: firstIdentifier,
                calendarIdentifier: calendarID
            )
        ])
        XCTAssertEqual(snapshot.recordsByTaskIdentifier[taskID]?.dueDate, updatedDueDate)
        try await service.updateReminderDueDate(identifier: firstIdentifier, dueDate: nil)
        snapshot = try await service.fetchReminderRecords(for: [
            ReminderLookupRequest(
                taskIdentifier: taskID,
                reminderIdentifier: firstIdentifier,
                calendarIdentifier: calendarID
            )
        ])
        XCTAssertNil(snapshot.recordsByTaskIdentifier[taskID]?.dueDate)

        try await service.updateReminderCompletion(
            identifier: firstIdentifier,
            isCompleted: true
        )
        created = try await reminders(in: [calendar], eventStore: eventStore)
            .filter { $0.title == title }
        XCTAssertTrue(try XCTUnwrap(created.first).isCompleted)

        try await service.updateReminderCompletion(
            identifier: firstIdentifier,
            isCompleted: false
        )
        created = try await reminders(in: [calendar], eventStore: eventStore)
            .filter { $0.title == title }
        XCTAssertFalse(try XCTUnwrap(created.first).isCompleted)

        // Changes made outside ReminderService are authoritative on the next read.
        let externallyEdited = try XCTUnwrap(
            eventStore.calendarItem(withIdentifier: firstIdentifier) as? EKReminder
        )
        externallyEdited.isCompleted = true
        try eventStore.save(externallyEdited, commit: true)
        snapshot = try await service.fetchReminderRecords(for: [
            ReminderLookupRequest(
                taskIdentifier: taskID,
                reminderIdentifier: firstIdentifier,
                calendarIdentifier: calendarID
            )
        ])
        record = try XCTUnwrap(snapshot.recordsByTaskIdentifier[taskID])
        XCTAssertTrue(record.isCompleted)

        externallyEdited.isCompleted = false
        try eventStore.save(externallyEdited, commit: true)
        snapshot = try await service.fetchReminderRecords(for: [
            ReminderLookupRequest(
                taskIdentifier: taskID,
                reminderIdentifier: firstIdentifier,
                calendarIdentifier: calendarID
            )
        ])
        record = try XCTUnwrap(snapshot.recordsByTaskIdentifier[taskID])
        XCTAssertFalse(record.isCompleted)

        // A stale identifier may point at another valid reminder. The stable task marker must
        // still resolve the reminder belonging to this recognized task.
        let otherTaskID = UUID()
        let otherIdentifier = try await service.createReminder(
            title: "Notizen other \(otherTaskID.uuidString)",
            isCompleted: true,
            taskID: otherTaskID
        )
        snapshot = try await service.fetchReminderRecords(for: [
            ReminderLookupRequest(
                taskIdentifier: taskID,
                reminderIdentifier: otherIdentifier,
                calendarIdentifier: calendarID
            )
        ])
        record = try XCTUnwrap(snapshot.recordsByTaskIdentifier[taskID])
        XCTAssertEqual(record.reminderIdentifier, firstIdentifier)
        XCTAssertFalse(record.isCompleted)

        // A missing record is confirmed deleted only while its owning list is still readable.
        try eventStore.remove(externallyEdited, commit: true)
        snapshot = try await service.fetchReminderRecords(for: [
            ReminderLookupRequest(
                taskIdentifier: taskID,
                reminderIdentifier: firstIdentifier,
                calendarIdentifier: calendarID
            )
        ])
        XCTAssertNil(snapshot.recordsByTaskIdentifier[taskID])
        XCTAssertTrue(snapshot.readableCalendarIdentifiers.contains(calendarID))

        // Even after A is deleted, A must not adopt B merely because its stale identifier now
        // resolves to B. B's different stable task marker proves that it belongs elsewhere.
        snapshot = try await service.fetchReminderRecords(for: [
            ReminderLookupRequest(
                taskIdentifier: taskID,
                reminderIdentifier: otherIdentifier,
                calendarIdentifier: calendarID
            )
        ])
        XCTAssertNil(snapshot.recordsByTaskIdentifier[taskID])
        XCTAssertTrue(snapshot.readableCalendarIdentifiers.contains(calendarID))

        do {
            _ = try await service.removeReminder(
                identifier: otherIdentifier, taskID: taskID,
                calendarIdentifier: calendarID
            )
            XCTFail("A stale identifier must not delete another task's reminder")
        } catch {
            // B's marker proves that the stale identifier is unrelated to A.
            XCTAssertEqual(error as? ReminderServiceError, .reminderNotFound)
        }

        // Removing by task marker must delete B while leaving already-removed A alone.
        let removed = try await service.removeReminder(
            identifier: otherIdentifier, taskID: otherTaskID,
            calendarIdentifier: calendarID
        )
        XCTAssertTrue(removed)
        let removedAgain = try await service.removeReminder(
            identifier: otherIdentifier, taskID: otherTaskID,
            calendarIdentifier: calendarID
        )
        XCTAssertFalse(removedAgain)
        snapshot = try await service.fetchReminderRecords(for: [
            ReminderLookupRequest(taskIdentifier: otherTaskID,
                                  reminderIdentifier: otherIdentifier,
                                  calendarIdentifier: calendarID)
        ])
        XCTAssertNil(snapshot.recordsByTaskIdentifier[otherTaskID])

        // Removing the explicitly selected list must make creation fail. The service may not
        // silently redirect the reminder to EventKit's default list.
        try eventStore.removeCalendar(calendar, commit: true)
        snapshot = try await service.fetchReminderRecords(for: [
            ReminderLookupRequest(
                taskIdentifier: otherTaskID,
                reminderIdentifier: otherIdentifier,
                calendarIdentifier: calendarID
            )
        ])
        XCTAssertNil(snapshot.recordsByTaskIdentifier[otherTaskID])
        XCTAssertFalse(
            snapshot.readableCalendarIdentifiers.contains(calendarID),
            "A removed or inaccessible owner list must leave reminder deletion unconfirmed"
        )

        let rejectedTitle = "Notizen rejected \(UUID().uuidString)"
        do {
            _ = try await service.createReminder(
                title: rejectedTitle,
                isCompleted: false,
                taskID: UUID()
            )
            XCTFail("Creation unexpectedly succeeded after the selected list was removed")
        } catch {
            let serviceError = try XCTUnwrap(error as? ReminderServiceError)
            XCTAssertTrue(
                serviceError == .noSelectedList || serviceError == .selectedListUnavailable,
                "Unexpected creation failure after removing the selected list: \(serviceError)"
            )
        }

        let remainingCalendars = eventStore.calendars(for: .reminder)
        let unexpectedReminders = try await reminders(
            in: remainingCalendars,
            eventStore: eventStore
        ).filter { $0.title == rejectedTitle }
        for reminder in unexpectedReminders {
            try? eventStore.remove(reminder, commit: false)
        }
        if !unexpectedReminders.isEmpty {
            try? eventStore.commit()
        }
        XCTAssertTrue(unexpectedReminders.isEmpty, "The rejected reminder was written to another list")
    }

    func testTimedReminderAlarmAndForeignAlarmSurviveScheduleChanges() async throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("The EventKit integration test is intentionally simulator-only.")
#endif
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw XCTSkip("The simulator has not granted full Reminders access to the test host.")
        }
        let eventStore = EKEventStore()
        guard let source = eventStore.sources.first(where: { $0.sourceType == .local }) else {
            throw XCTSkip("The simulator has no local EventKit source.")
        }
        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = "Notizen Alarms \(UUID().uuidString)"
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        defer {
            if let saved = eventStore.calendar(withIdentifier: calendar.calendarIdentifier) {
                try? eventStore.removeCalendar(saved, commit: true)
            }
        }

        let store = EventKitReminderStore(eventStore: eventStore)
        let taskID = UUID()
        let first = TaskDueDate(year: 2026, month: 10, day: 25, hour: 14, minute: 30)
        let second = TaskDueDate(year: 2026, month: 10, day: 26, hour: 9, minute: 15)
        let identifier = try await store.createReminder(
            title: "Alarm \(taskID.uuidString)", isCompleted: false,
            dueDate: first, alarmOffsetMinutes: 15,
            listIdentifier: calendar.calendarIdentifier, taskIdentifier: taskID
        )
        let created = try XCTUnwrap(eventStore.calendarItem(withIdentifier: identifier) as? EKReminder)
        XCTAssertEqual(created.dueDateComponents?.hour, 14)
        XCTAssertEqual(created.dueDateComponents?.minute, 30)
        XCTAssertEqual(created.startDateComponents?.hour, 14)
        XCTAssertEqual(alarmDates(created), [first.date.addingTimeInterval(-900)])

        let foreignDate = first.date.addingTimeInterval(-24 * 60 * 60)
        created.addAlarm(EKAlarm(absoluteDate: foreignDate))
        try eventStore.save(created, commit: true)
        try await store.setReminderSchedule(
            identifier: identifier, dueDate: second,
            alarmOffsetMinutes: 60, previousAlarmOffsetMinutes: 15
        )
        let changed = try XCTUnwrap(eventStore.calendarItem(withIdentifier: identifier) as? EKReminder)
        XCTAssertEqual(changed.dueDateComponents?.hour, 9)
        XCTAssertEqual(changed.startDateComponents?.hour, 9)
        XCTAssertEqual(Set(alarmDates(changed)),
                       Set([foreignDate, second.date.addingTimeInterval(-3600)]))

        let request = ReminderLookupRequest(
            taskIdentifier: taskID, reminderIdentifier: identifier,
            calendarIdentifier: calendar.calendarIdentifier
        )
        let snapshot = try await store.fetchReminderRecords(for: [request])
        XCTAssertEqual(snapshot.recordsByTaskIdentifier[taskID]?.dueDate, second)
        XCTAssertEqual(snapshot.recordsByTaskIdentifier[taskID]?.alarmOffsetMinutes, 60)

        try await store.setReminderSchedule(
            identifier: identifier, dueDate: second,
            alarmOffsetMinutes: nil, previousAlarmOffsetMinutes: 60
        )
        let cleared = try XCTUnwrap(eventStore.calendarItem(withIdentifier: identifier) as? EKReminder)
        XCTAssertEqual(alarmDates(cleared), [foreignDate])

        // A plain date edit must never remove unrelated EventKit alarms.
        try await store.setReminderDueDate(
            identifier: identifier, dueDate: TaskDueDate(year: 2026, month: 10, day: 27)
        )
        let allDay = try XCTUnwrap(eventStore.calendarItem(withIdentifier: identifier) as? EKReminder)
        XCTAssertNil(allDay.dueDateComponents?.hour)
        XCTAssertNil(allDay.startDateComponents)
        XCTAssertEqual(alarmDates(allDay), [foreignDate])
    }

    private func alarmDates(_ reminder: EKReminder) -> [Date] {
        (reminder.alarms.flatMap { $0 } ?? []).compactMap(\.absoluteDate)
    }

    private func reminders(
        in calendars: [EKCalendar],
        eventStore: EKEventStore
    ) async throws -> [EKReminder] {
        guard !calendars.isEmpty else { return [] }
        let predicate = eventStore.predicateForReminders(in: calendars)
        return try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: IntegrationError.fetchFailed)
                    return
                }
                continuation.resume(returning: reminders)
            }
        }
    }

    private enum IntegrationError: Error {
        case fetchFailed
    }
}
