import XCTest
@testable import Notizen

final class CustomerAssignmentPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1000)
    private let first = Customer(id: UUID(), name: "Erster Kunde", isArchived: false)
    private let second = Customer(id: UUID(), name: "Zweiter Kunde", isArchived: false)

    func testExplicitFolderAttachesUniqueMatchingEvent() {
        let meeting = event("first")
        let result = decision(collection: .customer(first.id), events: [meeting])
        XCTAssertEqual(result.customerID, first.id)
        XCTAssertEqual(result.event, meeting)
        XCTAssertFalse(result.needsChoice)
    }

    func testExplicitFolderIgnoresParallelBlocker() {
        let meeting = event("first")
        let result = decision(
            collection: .customer(first.id),
            events: [meeting, event("first", title: "Blocker")]
        )
        XCTAssertEqual(result.customerID, first.id)
        XCTAssertEqual(result.event, meeting)
        XCTAssertFalse(result.needsChoice)
    }

    func testExplicitFolderIgnoresOtherCustomersEvent() {
        let meeting = event("first")
        let result = decision(collection: .customer(first.id), events: [meeting, event("second")])
        XCTAssertEqual(result.customerID, first.id)
        XCTAssertEqual(result.event, meeting)
        XCTAssertFalse(result.needsChoice)
    }

    func testExplicitFolderWinsOverUnrelatedCalendarWithoutMatchingEvent() {
        let result = decision(collection: .customer(first.id), events: [event("second")])
        XCTAssertEqual(result.customerID, first.id)
        XCTAssertNil(result.event)
        XCTAssertFalse(result.needsChoice)
    }

    func testExplicitFolderDoesNotGuessBetweenMatchingEvents() {
        let result = decision(
            collection: .customer(first.id),
            events: [event("first"), event("first", title: "Zweite Besprechung")]
        )
        XCTAssertEqual(result.customerID, first.id)
        XCTAssertNil(result.event)
        XCTAssertFalse(result.needsChoice)
    }

    func testExplicitFolderDoesNotAttachEventWhenAutomationIsDisabled() {
        let result = decision(
            collection: .customer(first.id),
            automatic: false,
            events: [event("first")]
        )
        XCTAssertEqual(result.customerID, first.id)
        XCTAssertNil(result.event)
        XCTAssertFalse(result.needsChoice)
    }

    func testExplicitFolderUsesUpcomingEventWhenNoMatchingEventIsRunning() {
        let upcoming = event("first", startOffset: 10 * 60)
        let result = decision(collection: .customer(first.id), events: [upcoming])
        XCTAssertEqual(result.customerID, first.id)
        XCTAssertEqual(result.event, upcoming)
        XCTAssertFalse(result.needsChoice)
    }

    func testExplicitFolderFiltersCustomerBeforeChoosingCurrentOverUpcoming() {
        let selectedUpcoming = event("first", startOffset: 10 * 60)
        let otherCurrent = event("second")
        let result = decision(
            collection: .customer(first.id),
            events: [otherCurrent, selectedUpcoming]
        )
        XCTAssertEqual(result.customerID, first.id)
        XCTAssertEqual(result.event, selectedUpcoming)
        XCTAssertFalse(result.needsChoice)
    }

    func testUpcomingParallelCustomersRequireChoice() {
        let result = decision(events: [
            event("first", startOffset: 5 * 60),
            event("second", startOffset: 10 * 60)
        ])
        XCTAssertNil(result.customerID)
        XCTAssertNil(result.event)
        XCTAssertTrue(result.needsChoice)
    }

    func testUnassignedFolderAndDisabledAutomationRemainUnassigned() {
        for result in [decision(collection: .unassigned, events: [event("first")]),
                       decision(automatic: false, events: [event("first")])] {
            XCTAssertNil(result.customerID)
            XCTAssertNil(result.event)
            XCTAssertFalse(result.needsChoice)
        }
    }

    func testUniqueEventKeepsContextWhileBlockerIsIgnored() {
        let meeting = event("first")
        let result = decision(events: [meeting, event("second", title: "Blocker")])
        XCTAssertEqual(result.customerID, first.id)
        XCTAssertEqual(result.event, meeting)
        XCTAssertFalse(result.needsChoice)
    }

    func testParallelCustomersRequireChoiceWithoutGuessing() {
        let result = decision(events: [event("first"), event("second")])
        XCTAssertNil(result.customerID)
        XCTAssertNil(result.event)
        XCTAssertTrue(result.needsChoice)
    }

    func testSameCustomerAcrossCalendarsAssignsCustomerWithoutGuessingMeeting() {
        let result = CustomerAssignmentPolicy.decide(
            collection: .all, automatic: true, events: [event("first"), event("second")],
            at: now, mappings: ["first": first.id, "second": first.id], customers: [first]
        )
        XCTAssertEqual(result.customerID, first.id)
        XCTAssertNil(result.event)
        XCTAssertFalse(result.needsChoice)
    }

    private func decision(collection: NoteCollection = .all, automatic: Bool = true,
                          events: [CalendarEventSnapshot]) -> CustomerAssignmentDecision {
        CustomerAssignmentPolicy.decide(collection: collection, automatic: automatic, events: events,
            at: now, mappings: ["first": first.id, "second": second.id], customers: [first, second])
    }

    private func event(
        _ calendar: String,
        title: String = "Besprechung",
        startOffset: TimeInterval = -60
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: calendar, eventIdentifier: calendar, calendarIdentifier: calendar,
            calendarTitle: calendar, title: title, startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(startOffset + 20 * 60), isAllDay: false)
    }
}
