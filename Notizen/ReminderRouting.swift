import Foundation

struct ReminderRoutingDecision: Equatable {
    let targetListID: String?
    let suggestedListID: String?
    let requiresConfirmation: Bool
    let reason: String?
}

struct ReminderRoutingExample: Codable, Equatable {
    let noteID: UUID
    let customerID: UUID?
    let listID: String
    let context: String
    let confirmedAt: Date
}

enum ReminderRouting {
    static func context(note: Note, taskTitles: [String]) -> String {
        let eventTitle = note.calendarEvent?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([eventTitle].compactMap { $0?.isEmpty == false ? $0 : nil } + Array(taskTitles.prefix(3)))
            .joined(separator: " ")
    }

    static func decide(
        note: Note,
        customer: Customer?,
        examples: [ReminderRoutingExample],
        taskTitles: [String],
        lists: [ReminderList],
        globalListID: String
    ) -> ReminderRoutingDecision {
        let available = Set(lists.map(\.id))
        if let fixed = note.reminderListID {
            if available.contains(fixed) {
                return .init(targetListID: fixed, suggestedListID: fixed,
                             requiresConfirmation: false, reason: nil)
            }
            return .init(targetListID: nil, suggestedListID: fixed,
                         requiresConfirmation: true,
                         reason: "Die für diese Notiz gewählte Liste ist nicht verfügbar.")
        }

        let defaultID = customer?.defaultReminderListID
        if let defaultID, !available.contains(defaultID) {
            return .init(targetListID: nil, suggestedListID: defaultID,
                         requiresConfirmation: true,
                         reason: "Die Standardliste dieses Kunden ist nicht verfügbar.")
        }

        let associatedIDs: Set<String>
        if let customer {
            let configured = Set(customer.reminderListIDs + [customer.defaultReminderListID].compactMap { $0 })
            associatedIDs = configured.isEmpty ? available : configured.intersection(available)
        } else {
            associatedIDs = available
        }
        let candidates = lists.filter { associatedIDs.contains($0.id) }
        let context = context(note: note, taskTitles: taskTitles)
        let contextTokens = tokens(context, customerName: customer?.name)
        let titleMatches = candidates.filter { list in
            !tokens(list.title, customerName: customer?.name).isDisjoint(with: contextTokens)
        }
        let strongTitleID = titleMatches.count == 1 ? titleMatches[0].id : nil

        let matches = examples.filter { example in
            example.noteID != note.id &&
            example.customerID == note.customerID &&
            associatedIDs.contains(example.listID) &&
            !tokens(example.context, customerName: customer?.name).isDisjoint(with: contextTokens)
        }
        let counts = Dictionary(grouping: matches, by: \.listID).mapValues { $0.count }
        let ranked = counts.sorted { left, right in
            left.value == right.value ? left.key < right.key : left.value > right.value
        }
        let learnedID: String?
        if let first = ranked.first,
           first.value >= 2,
           (ranked.dropFirst().first?.value ?? 0) < first.value {
            learnedID = first.key
        } else {
            learnedID = nil
        }

        let suggested = strongTitleID ?? learnedID ?? defaultID ?? (available.contains(globalListID) ? globalListID : nil)
        if let defaultID {
            if let alternate = strongTitleID ?? learnedID, alternate != defaultID {
                let reason = strongTitleID == alternate
                    ? "Ein Begriff aus der Notiz passt zu einer anderen Kundenliste."
                    : "Bisherige Listenwahlen für ähnliche Notizen sprechen für eine andere Kundenliste."
                return .init(targetListID: nil, suggestedListID: alternate,
                             requiresConfirmation: true,
                             reason: reason)
            }
            return .init(targetListID: defaultID, suggestedListID: defaultID,
                         requiresConfirmation: false, reason: nil)
        }
        return .init(targetListID: nil, suggestedListID: suggested,
                     requiresConfirmation: true,
                     reason: "Wähle eine Liste für diese Notiz aus.")
    }

    private static let genericWords: Set<String> = [
        "allgemein", "aufgabe", "aufgaben", "besprechung", "bitte", "das", "dem", "den",
        "der", "die", "ein", "eine", "einer", "eines", "erinnerung", "erinnerungen",
        "fur", "fuer", "heute", "kunde", "kunden", "liste", "meeting", "mit", "morgen",
        "notiz", "notizen", "projekt", "projekte", "termin", "und", "vom", "von", "zum", "zur"
    ]

    private static func tokens(_ value: String, customerName: String?) -> Set<String> {
        let normalized = value.replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
        let customerWords: Set<String>
        if let customerName {
            customerWords = tokens(customerName, customerName: nil)
        } else {
            customerWords = []
        }
        return Set(normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !genericWords.contains($0) && !customerWords.contains($0) })
    }
}
