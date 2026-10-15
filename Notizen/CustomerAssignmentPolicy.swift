import Foundation

struct CustomerAssignmentDecision {
    let customerID: UUID?
    let event: CalendarEventSnapshot?
    let needsChoice: Bool
}

enum CustomerAssignmentPolicy {
    static func decide(
        collection: NoteCollection,
        automatic: Bool,
        events: [CalendarEventSnapshot],
        at date: Date,
        mappings: [String: UUID],
        customers: [Customer]
    ) -> CustomerAssignmentDecision {
        switch collection {
        case .customer(let id):
            guard automatic else {
                return CustomerAssignmentDecision(customerID: id, event: nil, needsChoice: false)
            }
            let customerEvents = events.filter { mappings[$0.calendarIdentifier] == id }
            let eligible = CalendarService.assignmentCandidates(
                customerEvents,
                at: date,
                mappings: mappings,
                customers: customers
            )
            return CustomerAssignmentDecision(
                customerID: id,
                event: eligible.count == 1 ? eligible.first : nil,
                needsChoice: false
            )
        case .unassigned:
            return CustomerAssignmentDecision(customerID: nil, event: nil, needsChoice: false)
        case .all:
            guard automatic else {
                return CustomerAssignmentDecision(customerID: nil, event: nil, needsChoice: false)
            }
            let eligible = CalendarService.assignmentCandidates(
                events,
                at: date,
                mappings: mappings,
                customers: customers
            )
            let ids = Set(eligible.compactMap { mappings[$0.calendarIdentifier] })
            return CustomerAssignmentDecision(
                customerID: ids.count == 1 ? ids.first : nil,
                event: eligible.count == 1 ? eligible.first : nil,
                needsChoice: ids.count > 1
            )
        }
    }
}
