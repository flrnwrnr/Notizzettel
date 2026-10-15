import Foundation
import XCTest

@testable import Notizen

final class CalendarMatchingTests: XCTestCase {
    private let customerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let instant = Date(timeIntervalSinceReferenceDate: 1_000)

    func testStartIsInclusiveAndEndIsExclusive() {
        let atStart = event(id: "start", start: instant, end: instant.addingTimeInterval(60))
        let atEnd = event(id: "end", start: instant.addingTimeInterval(-60), end: instant)

        XCTAssertEqual(eligible([atStart, atEnd]).map(\.id), ["start"])
    }

    func testReturnsEveryOverlappingEligibleEvent() {
        let first = event(id: "first", start: instant.addingTimeInterval(-30), end: instant.addingTimeInterval(30))
        let second = event(id: "second", start: instant.addingTimeInterval(-10), end: instant.addingTimeInterval(90))

        XCTAssertEqual(eligible([first, second]), [first, second])
    }

    func testFiltersUnmappedAndArchivedCustomerEvents() {
        let mapped = event(id: "mapped")
        let unmapped = event(id: "unmapped", calendarIdentifier: "other")

        XCTAssertEqual(eligible([mapped, unmapped]).map(\.id), ["mapped"])

        let archived = Customer(id: customerID, name: "Archived", isArchived: true)
        XCTAssertTrue(CalendarService.eligibleEvents(
            [mapped], at: instant, mappings: ["work": customerID], customers: [archived]
        ).isEmpty)
    }

    func testFiltersBlockerAllDayAndNoncurrentEvents() {
        let blocker = event(id: "blocker", title: "Focus BLOCKER")
        let allDay = event(id: "all-day", isAllDay: true)
        let future = event(id: "future", start: instant.addingTimeInterval(1), end: instant.addingTimeInterval(60))

        XCTAssertTrue(eligible([blocker, allDay, future]).isEmpty)
    }

    func testNoCustomerMatchReturnsNoEvents() {
        let unknownID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        XCTAssertTrue(CalendarService.eligibleEvents(
            [event(id: "event")],
            at: instant,
            mappings: ["work": unknownID],
            customers: [Customer(id: customerID, name: "Known", isArchived: false)]
        ).isEmpty)
    }

    func testAssignmentCandidatesIncludeUpcomingEventsThroughFifteenMinutes() {
        let justAhead = event(
            id: "just-ahead",
            start: instant.addingTimeInterval(1),
            end: instant.addingTimeInterval(901)
        )
        let atBoundary = event(
            id: "boundary",
            start: instant.addingTimeInterval(15 * 60),
            end: instant.addingTimeInterval(20 * 60)
        )
        let tooLate = event(
            id: "too-late",
            start: instant.addingTimeInterval(15 * 60 + 1),
            end: instant.addingTimeInterval(20 * 60)
        )
        let alreadyEnded = event(
            id: "already-ended",
            start: instant.addingTimeInterval(-120),
            end: instant.addingTimeInterval(-1)
        )

        XCTAssertEqual(
            candidates([alreadyEnded, justAhead, atBoundary, tooLate]),
            [justAhead, atBoundary]
        )
    }

    func testAssignmentCandidatesPreferCurrentEventOverUpcomingEvent() {
        let current = event(id: "current")
        let upcoming = event(
            id: "upcoming",
            start: instant.addingTimeInterval(5 * 60),
            end: instant.addingTimeInterval(20 * 60)
        )

        XCTAssertEqual(candidates([upcoming, current]), [current])
    }

    func testAssignmentCandidatesExcludeFutureBlockerAndArchivedCustomer() {
        let blocker = event(
            id: "blocker",
            title: "Focus Blocker",
            start: instant.addingTimeInterval(5 * 60),
            end: instant.addingTimeInterval(20 * 60)
        )
        XCTAssertTrue(candidates([blocker]).isEmpty)

        let archived = Customer(id: customerID, name: "Archived", isArchived: true)
        XCTAssertTrue(CalendarService.assignmentCandidates(
            [event(id: "future", start: instant.addingTimeInterval(60))],
            at: instant,
            mappings: ["work": customerID],
            customers: [archived]
        ).isEmpty)
    }

    private func eligible(_ events: [CalendarEventSnapshot]) -> [CalendarEventSnapshot] {
        CalendarService.eligibleEvents(
            events,
            at: instant,
            mappings: ["work": customerID],
            customers: [Customer(id: customerID, name: "Customer", isArchived: false)]
        )
    }

    private func candidates(_ events: [CalendarEventSnapshot]) -> [CalendarEventSnapshot] {
        CalendarService.assignmentCandidates(
            events,
            at: instant,
            mappings: ["work": customerID],
            customers: [Customer(id: customerID, name: "Customer", isArchived: false)]
        )
    }

    private func event(
        id: String,
        calendarIdentifier: String = "work",
        title: String = "Meeting",
        start: Date? = nil,
        end: Date? = nil,
        isAllDay: Bool = false
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: id,
            eventIdentifier: id,
            calendarIdentifier: calendarIdentifier,
            calendarTitle: "Work",
            title: title,
            startDate: start ?? instant.addingTimeInterval(-60),
            endDate: end ?? instant.addingTimeInterval(60),
            isAllDay: isAllDay
        )
    }
}
