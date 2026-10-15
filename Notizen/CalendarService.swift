import Combine
import Foundation
@preconcurrency import EventKit

struct CalendarSource: Identifiable, Equatable {
    let id: String
    let title: String
    let sourceTitle: String
}

private enum CalendarServiceError: LocalizedError {
    case accessDenied
    case accessRequestFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Der Zugriff auf Kalenderereignisse wurde nicht erlaubt."
        case .accessRequestFailed:
            return "Der Kalenderzugriff konnte nicht angefragt werden."
        }
    }
}

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var calendars: [CalendarSource] = []
    @Published private(set) var hasAccess = false
    @Published private(set) var isRequestingAccess = false
    @Published var errorMessage: String?

    private let eventStore: EKEventStore
    private var eventStoreChangeCancellable: AnyCancellable?

    init(
        eventStore: EKEventStore = EKEventStore(),
        observeEventStoreChanges: Bool = true
    ) {
        self.eventStore = eventStore
        refresh()

        if observeEventStoreChanges {
            eventStoreChangeCancellable = NotificationCenter.default.publisher(
                for: .EKEventStoreChanged,
                object: eventStore
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }
    }

    func requestAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        errorMessage = nil
        defer { isRequestingAccess = false }

        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            if granted {
                refresh()
            } else {
                hasAccess = false
                errorMessage = CalendarServiceError.accessDenied.localizedDescription
            }
        } catch {
            hasAccess = false
            errorMessage = error.localizedDescription.isEmpty
                ? CalendarServiceError.accessRequestFailed.localizedDescription
                : error.localizedDescription
        }
    }

    func refresh() {
        let authorization = EKEventStore.authorizationStatus(for: .event)
        hasAccess = authorization == .fullAccess
        guard hasAccess else {
            if authorization == .denied || authorization == .restricted {
                errorMessage = CalendarServiceError.accessDenied.localizedDescription
            }
            return
        }

        errorMessage = nil
        calendars = eventStore.calendars(for: .event)
            .map {
                CalendarSource(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source.title
                )
            }
            .sorted {
                if $0.sourceTitle == $1.sourceTitle {
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.sourceTitle.localizedStandardCompare($1.sourceTitle) == .orderedAscending
            }
    }

    func events(on date: Date) -> [CalendarEventSnapshot] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }

        let predicate = eventStore.predicateForEvents(
            withStart: dayStart,
            end: dayEnd,
            calendars: nil
        )
        return eventStore.events(matching: predicate)
            .filter { $0.status != .canceled && !Self.isDeclined($0) }
            .map(Self.snapshot)
            .sorted {
                if $0.startDate == $1.startDate { return $0.endDate < $1.endDate }
                return $0.startDate < $1.startDate
            }
    }

    func currentEvents(at date: Date) -> [CalendarEventSnapshot] {
        events(on: date).filter { event in
            !event.isAllDay
                && !event.title.localizedCaseInsensitiveContains("Blocker")
                && event.startDate <= date
                && date < event.endDate
        }
    }

    func assignmentEvents(at date: Date) -> [CalendarEventSnapshot] {
        let calendar = Calendar.current
        let windowEnd = date.addingTimeInterval(15 * 60)
        var candidates = events(on: date)
        if !calendar.isDate(date, inSameDayAs: windowEnd) {
            candidates.append(contentsOf: events(on: windowEnd))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    nonisolated static func eligibleEvents(
        _ events: [CalendarEventSnapshot],
        at date: Date,
        mappings: [String: UUID],
        customers: [Customer]
    ) -> [CalendarEventSnapshot] {
        eligibleMappedEvents(events, mappings: mappings, customers: customers).filter { event in
            event.startDate <= date && date < event.endDate
        }
    }

    nonisolated static func assignmentCandidates(
        _ events: [CalendarEventSnapshot],
        at date: Date,
        mappings: [String: UUID],
        customers: [Customer]
    ) -> [CalendarEventSnapshot] {
        let eligible = eligibleMappedEvents(events, mappings: mappings, customers: customers)
        let current = eligible.filter { $0.startDate <= date && date < $0.endDate }
        guard current.isEmpty else { return current }

        let windowEnd = date.addingTimeInterval(15 * 60)
        return eligible.filter { date < $0.startDate && $0.startDate <= windowEnd }
    }

    nonisolated private static func eligibleMappedEvents(
        _ events: [CalendarEventSnapshot],
        mappings: [String: UUID],
        customers: [Customer]
    ) -> [CalendarEventSnapshot] {
        let activeCustomerIDs = Set(customers.lazy.filter { !$0.isArchived }.map(\.id))
        return events.filter { event in
            guard !event.isAllDay,
                  !event.title.localizedCaseInsensitiveContains("Blocker"),
                  let customerID = mappings[event.calendarIdentifier]
            else { return false }
            return activeCustomerIDs.contains(customerID)
        }
    }

    private static func snapshot(_ event: EKEvent) -> CalendarEventSnapshot {
        let occurrenceIdentifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let id = [
            event.calendar.calendarIdentifier,
            occurrenceIdentifier,
            String(event.startDate.timeIntervalSinceReferenceDate.bitPattern)
        ].joined(separator: "|")
        return CalendarEventSnapshot(
            id: id,
            eventIdentifier: event.eventIdentifier,
            calendarIdentifier: event.calendar.calendarIdentifier,
            calendarTitle: event.calendar.title,
            title: event.title ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay
        )
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        } == true
    }
}
