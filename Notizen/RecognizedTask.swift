import Foundation
import CoreGraphics

/// Transient OCR output. Persistent `RecognizedTask` values may be linked to Reminders.
struct TaskCandidate: Sendable {
    let bounds: CGRect
    let text: String
    let confidence: Float
    let isChecked: Bool
}

enum TaskReminderStatus: String, Codable, Equatable, Sendable {
    case open
    case completed
    case deleted
}

enum TaskDueDateSource: String, Codable, Equatable, Sendable {
    case automatic
    case manual
    case external
}

enum TaskMarkerState: Equatable, Sendable {
    case proposal
    case open
    case completed
    case deleted
}

/// A calendar day with an optional local clock time. Missing time means all-day.
struct TaskDueDate: Codable, Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int?
    let minute: Int?

    init(year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil) {
        precondition(Self.isValid(year: year, month: month, day: day, hour: hour, minute: minute))
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    init(date: Date) {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year!, month: components.month!, day: components.day!)
    }

    var date: Date {
        // Untimed days use midday so date-only conversions stay stable at DST boundaries.
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: year, month: month, day: day,
                                 hour: hour ?? 12, minute: minute ?? 0)
        )!
    }

    var hasTime: Bool { hour != nil }

    private enum CodingKeys: String, CodingKey { case year, month, day, hour, minute }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let year = try container.decode(Int.self, forKey: .year)
        let month = try container.decode(Int.self, forKey: .month)
        let day = try container.decode(Int.self, forKey: .day)
        let hour = try container.decodeIfPresent(Int.self, forKey: .hour)
        let minute = try container.decodeIfPresent(Int.self, forKey: .minute)
        guard Self.isValid(year: year, month: month, day: day, hour: hour, minute: minute) else {
            throw DecodingError.dataCorruptedError(
                forKey: .day, in: container, debugDescription: "Invalid due date or time"
            )
        }
        self.init(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    static func isValid(
        year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil
    ) -> Bool {
        guard (hour == nil) == (minute == nil) else { return false }
        if let hour, let minute {
            guard (0...23).contains(hour), (0...59).contains(minute) else { return false }
        }
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return false
        }
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year && components.month == month && components.day == day else {
            return false
        }
        guard let hour, let minute else { return true }
        guard let timed = calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )) else { return false }
        let resolved = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timed)
        return resolved.year == year && resolved.month == month && resolved.day == day
            && resolved.hour == hour && resolved.minute == minute
    }
}

struct RecognizedTask: Identifiable, Codable, Equatable {
    var id: UUID
    var bounds: CGRect
    var recognizedText: String
    var correctedText: String?
    var confidence: Float
    var isChecked: Bool
    var reminderIdentifier: String?
    var reminderCalendarIdentifier: String?
    var reminderStatus: TaskReminderStatus?
    var isPresent: Bool
    var reminderSyncError: String?
    var dueDate: TaskDueDate?
    /// nil disables the app alarm; zero fires at the due time.
    var reminderAlarmOffsetMinutes: Int?
    /// The app alarm most recently confirmed in Reminders.
    var reminderLastSyncedAlarmOffsetMinutes: Int?
    var alarmSyncPending: Bool

    /// A source also owns an empty date: clearing a date must not make OCR set it again.
    var dueDateSource: TaskDueDateSource?
    var dueDateReferenceDate: TaskDueDate?
    var dueDateReferenceIsTrusted: Bool
    var dueDateLastAnalyzedText: String?
    var dueDateProposal: TaskDueDateSuggestion?

    /// A local date edit takes priority over an in-flight Reminders readback.
    var reminderDueDateSyncPending: Bool
    var isIgnored: Bool
    var reminderRemovalPending: Bool
    var wasRemovedFromDrawing: Bool
    var reminderRestorePending: Bool
    /// Quantized visible checkbox-frame samples from a committed drawing.
    var checkboxInkEvidence: [Int]?
    var checkboxStrokeEvidence: [String]?

    /// The handwriting state most recently written to the linked reminder.
    /// Keeping this separate from `isChecked` prevents opening a note from
    /// overwriting a completion change made in Reminders.
    var reminderLastSyncedIsChecked: Bool?

    var title: String { correctedText ?? recognizedText }

    var markerState: TaskMarkerState {
        guard reminderIdentifier != nil else { return .proposal }
        switch reminderStatus {
        case .open:
            return .open
        case .completed:
            return .completed
        case .deleted:
            return .deleted
        case nil:
            return reminderLastSyncedIsChecked == true ? .completed : .open
        }
    }

    init(
        id: UUID,
        bounds: CGRect,
        recognizedText: String,
        correctedText: String?,
        confidence: Float,
        isChecked: Bool,
        reminderIdentifier: String? = nil,
        reminderCalendarIdentifier: String? = nil,
        reminderStatus: TaskReminderStatus? = nil,
        isPresent: Bool = true,
        reminderSyncError: String? = nil,
        reminderLastSyncedIsChecked: Bool? = nil,
        dueDate: TaskDueDate? = nil,
        reminderAlarmOffsetMinutes: Int? = nil,
        reminderLastSyncedAlarmOffsetMinutes: Int? = nil,
        alarmSyncPending: Bool = false,
        dueDateSource: TaskDueDateSource? = nil,
        dueDateReferenceDate: TaskDueDate? = nil,
        dueDateReferenceIsTrusted: Bool = false,
        dueDateLastAnalyzedText: String? = nil,
        dueDateProposal: TaskDueDateSuggestion? = nil,
        reminderDueDateSyncPending: Bool = false,
        isIgnored: Bool = false,
        reminderRemovalPending: Bool = false,
        wasRemovedFromDrawing: Bool = false,
        reminderRestorePending: Bool = false,
        checkboxInkEvidence: [Int]? = nil,
        checkboxStrokeEvidence: [String]? = nil
    ) {
        self.id = id
        self.bounds = bounds
        self.recognizedText = recognizedText
        self.correctedText = correctedText
        self.confidence = confidence
        self.isChecked = isChecked
        self.reminderIdentifier = reminderIdentifier
        self.reminderCalendarIdentifier = reminderCalendarIdentifier
        self.reminderStatus = reminderStatus
        self.isPresent = isPresent
        self.reminderSyncError = reminderSyncError
        self.reminderLastSyncedIsChecked = reminderLastSyncedIsChecked
        self.dueDate = dueDate
        self.reminderAlarmOffsetMinutes = reminderAlarmOffsetMinutes
        self.reminderLastSyncedAlarmOffsetMinutes = reminderLastSyncedAlarmOffsetMinutes
        self.alarmSyncPending = alarmSyncPending
        self.dueDateSource = dueDateSource
            ?? (dueDate != nil ? .manual
                : (reminderIdentifier != nil && dueDateReferenceDate == nil ? .external : nil))
        self.dueDateReferenceDate = dueDateReferenceDate
        self.dueDateReferenceIsTrusted = dueDateReferenceIsTrusted
        self.dueDateLastAnalyzedText = dueDateLastAnalyzedText
        self.dueDateProposal = dueDateProposal
        self.reminderDueDateSyncPending = reminderDueDateSyncPending
        self.isIgnored = isIgnored
        self.reminderRemovalPending = reminderRemovalPending
        self.wasRemovedFromDrawing = wasRemovedFromDrawing
        self.reminderRestorePending = reminderRestorePending
        self.checkboxInkEvidence = checkboxInkEvidence
        self.checkboxStrokeEvidence = checkboxStrokeEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bounds
        case recognizedText
        case correctedText
        case confidence
        case isChecked
        case reminderIdentifier
        case reminderCalendarIdentifier
        case reminderStatus
        case isPresent
        case reminderSyncError
        case reminderLastSyncedIsChecked
        case dueDate
        case reminderAlarmOffsetMinutes, reminderLastSyncedAlarmOffsetMinutes, alarmSyncPending
        case dueDateSource, dueDateReferenceDate, dueDateReferenceIsTrusted
        case dueDateLastAnalyzedText, dueDateProposal
        case reminderDueDateSyncPending
        case isIgnored, reminderRemovalPending, wasRemovedFromDrawing
        case reminderRestorePending, checkboxInkEvidence, checkboxStrokeEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        bounds = try container.decode(CGRect.self, forKey: .bounds)
        recognizedText = try container.decode(String.self, forKey: .recognizedText)
        correctedText = try container.decodeIfPresent(String.self, forKey: .correctedText)
        confidence = try container.decode(Float.self, forKey: .confidence)
        isChecked = try container.decode(Bool.self, forKey: .isChecked)
        reminderIdentifier = try container.decodeIfPresent(String.self, forKey: .reminderIdentifier)
        reminderCalendarIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .reminderCalendarIdentifier
        )
        reminderStatus = try container.decodeIfPresent(TaskReminderStatus.self, forKey: .reminderStatus)
        isPresent = try container.decodeIfPresent(Bool.self, forKey: .isPresent) ?? true
        reminderSyncError = try container.decodeIfPresent(String.self, forKey: .reminderSyncError)
        reminderLastSyncedIsChecked = try container.decodeIfPresent(
            Bool.self,
            forKey: .reminderLastSyncedIsChecked
        )
        dueDate = try container.decodeIfPresent(TaskDueDate.self, forKey: .dueDate)
        reminderAlarmOffsetMinutes = try container.decodeIfPresent(
            Int.self, forKey: .reminderAlarmOffsetMinutes
        )
        reminderLastSyncedAlarmOffsetMinutes = try container.decodeIfPresent(
            Int.self, forKey: .reminderLastSyncedAlarmOffsetMinutes
        )
        alarmSyncPending = try container.decodeIfPresent(Bool.self, forKey: .alarmSyncPending) ?? false
        dueDateReferenceDate = try container.decodeIfPresent(TaskDueDate.self, forKey: .dueDateReferenceDate)
        dueDateSource = try container.decodeIfPresent(TaskDueDateSource.self, forKey: .dueDateSource)
            ?? (dueDate != nil ? .manual
                : (reminderIdentifier != nil && dueDateReferenceDate == nil ? .external : nil))
        dueDateReferenceIsTrusted = try container.decodeIfPresent(
            Bool.self, forKey: .dueDateReferenceIsTrusted
        ) ?? false
        dueDateLastAnalyzedText = try container.decodeIfPresent(
            String.self, forKey: .dueDateLastAnalyzedText
        )
        dueDateProposal = try container.decodeIfPresent(
            TaskDueDateSuggestion.self, forKey: .dueDateProposal
        )
        reminderDueDateSyncPending = try container.decodeIfPresent(
            Bool.self, forKey: .reminderDueDateSyncPending
        ) ?? false
        isIgnored = try container.decodeIfPresent(Bool.self, forKey: .isIgnored) ?? false
        reminderRemovalPending = try container.decodeIfPresent(Bool.self, forKey: .reminderRemovalPending) ?? false
        wasRemovedFromDrawing = try container.decodeIfPresent(Bool.self, forKey: .wasRemovedFromDrawing) ?? false
        reminderRestorePending = try container.decodeIfPresent(Bool.self, forKey: .reminderRestorePending) ?? false
        checkboxInkEvidence = try container.decodeIfPresent([Int].self, forKey: .checkboxInkEvidence)
        checkboxStrokeEvidence = try container.decodeIfPresent([String].self, forKey: .checkboxStrokeEvidence)
    }
}
