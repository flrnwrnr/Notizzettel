@preconcurrency import EventKit
import Foundation
import XCTest

@testable import Notizen

@MainActor
final class CalendarEventKitIntegrationTests: XCTestCase {
    func testRealEventsAreReadFilteredAndPersistedAsSnapshots() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("The EventKit integration test is intentionally simulator-only.")
#endif

        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("The simulator has not granted full Calendar access to the test host.")
        }

        let eventStore = EKEventStore()
        guard let localSource = eventStore.sources.first(where: { $0.sourceType == .local }) else {
            throw XCTSkip("The simulator has no local EventKit source for a temporary event calendar.")
        }

        let fileManager = FileManager.default
        let storageURL = fileManager.temporaryDirectory.appendingPathComponent(
            "CalendarEventKitIntegrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = "Notizen Calendar Integration \(UUID().uuidString)"
        calendar.source = localSource
        try eventStore.saveCalendar(calendar, commit: true)
        let calendarID = calendar.calendarIdentifier

        defer {
            if let remainingCalendar = eventStore.calendar(withIdentifier: calendarID) {
                try? eventStore.removeCalendar(remainingCalendar, commit: true)
            }
            try? fileManager.removeItem(at: storageURL)
        }

        XCTAssertTrue(calendar.allowsContentModifications)

        let now = Date()
        let visibleTitle = "Notizen visible \(UUID().uuidString)"
        let visibleEvent = makeEvent(
            title: visibleTitle,
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1_200),
            calendar: calendar,
            eventStore: eventStore
        )
        try eventStore.save(visibleEvent, span: .thisEvent, commit: false)

        let blockerTitle = "Notizen BLOCKER \(UUID().uuidString)"
        let blockerEvent = makeEvent(
            title: blockerTitle,
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1_200),
            calendar: calendar,
            eventStore: eventStore
        )
        try eventStore.save(blockerEvent, span: .thisEvent, commit: false)

        let systemCalendar = Calendar(identifier: .gregorian)
        let tomorrow = try XCTUnwrap(
            systemCalendar.date(byAdding: .day, value: 1, to: systemCalendar.startOfDay(for: now))
        )
        let recurrenceStart = try XCTUnwrap(
            systemCalendar.date(byAdding: .hour, value: 12, to: tomorrow)
        )
        let recurringTitle = "Notizen recurring \(UUID().uuidString)"
        let recurringEvent = makeEvent(
            title: recurringTitle,
            start: recurrenceStart,
            end: recurrenceStart.addingTimeInterval(1_800),
            calendar: calendar,
            eventStore: eventStore
        )
        recurringEvent.addRecurrenceRule(
            EKRecurrenceRule(
                recurrenceWith: .daily,
                interval: 1,
                end: EKRecurrenceEnd(occurrenceCount: 2)
            )
        )
        try eventStore.save(recurringEvent, span: .thisEvent, commit: false)
        let midnightTitle = "Notizen midnight \(UUID().uuidString)"
        let midnightEvent = makeEvent(
            title: midnightTitle, start: tomorrow.addingTimeInterval(300),
            end: tomorrow.addingTimeInterval(900), calendar: calendar, eventStore: eventStore
        )
        try eventStore.save(midnightEvent, span: .thisEvent, commit: false)
        try eventStore.commit()

        let service = CalendarService(
            eventStore: eventStore,
            observeEventStoreChanges: false
        )
        service.refresh()
        XCTAssertEqual(service.calendars.first(where: { $0.id == calendarID })?.title, calendar.title)

        XCTAssertTrue(service.assignmentEvents(at: tomorrow.addingTimeInterval(-300))
            .contains(where: { $0.title == midnightTitle }))

        let daySnapshots = service.events(on: now)
        let visibleSnapshot = try XCTUnwrap(daySnapshots.first(where: { $0.title == visibleTitle }))
        XCTAssertEqual(visibleSnapshot.calendarIdentifier, calendarID)
        XCTAssertEqual(visibleSnapshot.calendarTitle, calendar.title)
        XCTAssertEqual(visibleSnapshot.eventIdentifier, visibleEvent.eventIdentifier)
        XCTAssertTrue(service.currentEvents(at: now).contains(where: { $0.title == visibleTitle }))
        XCTAssertFalse(service.currentEvents(at: now).contains(where: { $0.title == blockerTitle }))

        let firstOccurrence = try XCTUnwrap(
            service.events(on: recurrenceStart).first(where: { $0.title == recurringTitle })
        )
        let secondOccurrenceDate = try XCTUnwrap(
            systemCalendar.date(byAdding: .day, value: 1, to: recurrenceStart)
        )
        let secondOccurrence = try XCTUnwrap(
            service.events(on: secondOccurrenceDate).first(where: { $0.title == recurringTitle })
        )
        XCTAssertNotEqual(firstOccurrence.id, secondOccurrence.id)
        XCTAssertNotEqual(firstOccurrence.startDate, secondOccurrence.startDate)

        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let customer = try XCTUnwrap(store.createCustomer(name: "Persistent Customer"))
        store.setCalendarCustomer(calendarID, customerID: customer.id)
        store.setAutomaticCustomerAssignment(true)
        // A note often starts a few minutes before the meeting. Exercise the
        // real EventKit → matching policy → persistence path in both contexts.
        for creationDate in [now, now.addingTimeInterval(-600)] {
            let candidateEvents = service.assignmentEvents(at: creationDate)
            for collection in [NoteCollection.all, .customer(customer.id)] {
                let decision = CustomerAssignmentPolicy.decide(
                    collection: collection, automatic: store.automaticallyAssignCustomers,
                    events: candidateEvents, at: creationDate,
                    mappings: store.calendarCustomerMappings, customers: store.customers
                )
                XCTAssertEqual(decision.customerID, customer.id)
                XCTAssertEqual(decision.event, visibleSnapshot)
                XCTAssertFalse(decision.needsChoice)
                let automaticallyCreatedNote = try XCTUnwrap(
                    store.createNote(customerID: decision.customerID, event: decision.event)
                )
                XCTAssertEqual(automaticallyCreatedNote.calendarEvent, visibleSnapshot)
            }
        }
        let note = try XCTUnwrap(store.notes.first)

        try eventStore.removeCalendar(calendar, commit: true)
        service.refresh()
        XCTAssertFalse(service.calendars.contains(where: { $0.id == calendarID }))

        let reloadedStore = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        XCTAssertEqual(reloadedStore.customer(for: customer.id), customer)
        XCTAssertEqual(reloadedStore.calendarCustomerMappings[calendarID], customer.id)
        let reloadedNote = try XCTUnwrap(reloadedStore.notes.first(where: { $0.id == note.id }))
        XCTAssertEqual(reloadedNote.customerID, customer.id)
        XCTAssertEqual(reloadedNote.calendarEvent, visibleSnapshot)
    }

    private func makeEvent(
        title: String,
        start: Date,
        end: Date,
        calendar: EKCalendar,
        eventStore: EKEventStore
    ) -> EKEvent {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        return event
    }
}
