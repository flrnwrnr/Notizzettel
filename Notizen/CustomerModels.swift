import Foundation

struct Customer: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isArchived: Bool
    var defaultReminderListID: String?
    var reminderListIDs: [String]

    init(
        id: UUID,
        name: String,
        isArchived: Bool,
        defaultReminderListID: String? = nil,
        reminderListIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.isArchived = isArchived
        self.defaultReminderListID = defaultReminderListID
        self.reminderListIDs = reminderListIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isArchived, defaultReminderListID, reminderListIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        defaultReminderListID = try container.decodeIfPresent(String.self, forKey: .defaultReminderListID)
        reminderListIDs = try container.decodeIfPresent([String].self, forKey: .reminderListIDs) ?? []
    }
}

struct CalendarEventSnapshot: Identifiable, Codable, Equatable {
    let id: String
    let eventIdentifier: String?
    let calendarIdentifier: String
    let calendarTitle: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
}
