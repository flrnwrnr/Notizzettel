import Combine
@preconcurrency import EventKit
import Foundation

struct ReminderList: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
}

struct ReminderLookupRequest: Equatable, Sendable {
    let taskIdentifier: UUID
    let reminderIdentifier: String?
    let calendarIdentifier: String?
}

struct ReminderRecord: Equatable, Sendable {
    let taskIdentifier: UUID
    let reminderIdentifier: String
    let calendarIdentifier: String
    let isCompleted: Bool
    let dueDate: TaskDueDate?
    let alarmOffsetMinutes: Int?

    init(taskIdentifier: UUID, reminderIdentifier: String, calendarIdentifier: String,
         isCompleted: Bool, dueDate: TaskDueDate? = nil,
         alarmOffsetMinutes: Int? = nil) {
        self.taskIdentifier = taskIdentifier
        self.reminderIdentifier = reminderIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.alarmOffsetMinutes = alarmOffsetMinutes
    }
}

struct ReminderReadSnapshot: Equatable, Sendable {
    let recordsByTaskIdentifier: [UUID: ReminderRecord]
    let readableCalendarIdentifiers: Set<String>
}

enum ReminderAuthorization: Equatable, Sendable {
    case notDetermined
    case fullAccess
    case denied
}

enum ReminderServiceError: LocalizedError, Equatable {
    case noAccess
    case noSelectedList
    case selectedListUnavailable
    case originalListUnavailable
    case reminderNotFound
    case fetchFailed
    case statusReadUnsupported
    case dueDateUpdateUnsupported
    case alarmUpdateUnsupported
    case alarmRequiresTimedDueDate
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return "Der Zugriff auf Erinnerungen ist nicht erlaubt."
        case .noSelectedList:
            return "Wähle zuerst eine Erinnerungsliste aus."
        case .selectedListUnavailable:
            return "Die gewählte Erinnerungsliste ist nicht mehr verfügbar."
        case .originalListUnavailable:
            return "Die ursprüngliche Erinnerungsliste ist derzeit nicht verfügbar."
        case .reminderNotFound:
            return "Die verknüpfte Erinnerung wurde nicht gefunden."
        case .fetchFailed:
            return "Vorhandene Erinnerungen konnten nicht geprüft werden."
        case .statusReadUnsupported:
            return "Der Erinnerungsstatus kann hier nicht gelesen werden."
        case .dueDateUpdateUnsupported:
            return "Das Fälligkeitsdatum kann hier nicht geändert werden."
        case .alarmUpdateUnsupported:
            return "Der Erinnerungsalarm kann hier nicht geändert werden."
        case .alarmRequiresTimedDueDate:
            return "Wähle eine Uhrzeit für den Erinnerungsalarm."
        case let .saveFailed(message):
            return "Die Erinnerung konnte nicht gespeichert werden: \(message)"
        }
    }
}

@MainActor
protocol ReminderStore: AnyObject {
    func authorizationStatus() -> ReminderAuthorization
    func requestFullAccess() async throws -> Bool
    func writableLists() -> [ReminderList]
    func defaultListIdentifier() -> String?
    func createReminder(
        title: String,
        isCompleted: Bool,
        listIdentifier: String,
        taskIdentifier: UUID
    ) async throws -> String
    func createReminder(
        title: String,
        isCompleted: Bool,
        dueDate: TaskDueDate?,
        alarmOffsetMinutes: Int?,
        listIdentifier: String,
        taskIdentifier: UUID
    ) async throws -> String
    func createReminder(
        title: String,
        isCompleted: Bool,
        dueDate: TaskDueDate?,
        listIdentifier: String,
        taskIdentifier: UUID
    ) async throws -> String
    func setReminderCompleted(identifier: String, isCompleted: Bool) async throws
    func setReminderDueDate(identifier: String, dueDate: TaskDueDate?) async throws
    func setReminderSchedule(
        identifier: String, dueDate: TaskDueDate?, alarmOffsetMinutes: Int?,
        previousAlarmOffsetMinutes: Int?
    ) async throws
    func removeReminder(
        identifier: String, taskIdentifier: UUID, calendarIdentifier: String?
    ) async throws -> Bool
    func fetchReminderRecords(
        for requests: [ReminderLookupRequest]
    ) async throws -> ReminderReadSnapshot
}

extension ReminderStore {
    func createReminder(
        title: String, isCompleted: Bool, dueDate: TaskDueDate?,
        alarmOffsetMinutes: Int?, listIdentifier: String, taskIdentifier: UUID
    ) async throws -> String {
        guard alarmOffsetMinutes == nil else {
            throw ReminderServiceError.alarmUpdateUnsupported
        }
        return try await createReminder(
            title: title, isCompleted: isCompleted, dueDate: dueDate,
            listIdentifier: listIdentifier, taskIdentifier: taskIdentifier
        )
    }

    func createReminder(
        title: String, isCompleted: Bool, dueDate: TaskDueDate?,
        listIdentifier: String, taskIdentifier: UUID
    ) async throws -> String {
        let identifier = try await createReminder(
            title: title, isCompleted: isCompleted,
            listIdentifier: listIdentifier, taskIdentifier: taskIdentifier
        )
        if let dueDate {
            try await setReminderDueDate(identifier: identifier, dueDate: dueDate)
        }
        return identifier
    }

    func setReminderDueDate(identifier: String, dueDate: TaskDueDate?) async throws {
        throw ReminderServiceError.dueDateUpdateUnsupported
    }

    func setReminderSchedule(
        identifier: String, dueDate: TaskDueDate?, alarmOffsetMinutes: Int?,
        previousAlarmOffsetMinutes: Int?
    ) async throws {
        guard alarmOffsetMinutes == nil, previousAlarmOffsetMinutes == nil else {
            throw ReminderServiceError.alarmUpdateUnsupported
        }
        try await setReminderDueDate(identifier: identifier, dueDate: dueDate)
    }

    func removeReminder(
        identifier: String, taskIdentifier: UUID, calendarIdentifier: String?
    ) async throws -> Bool {
        throw ReminderServiceError.statusReadUnsupported
    }

    func fetchReminderRecords(
        for requests: [ReminderLookupRequest]
    ) async throws -> ReminderReadSnapshot {
        throw ReminderServiceError.statusReadUnsupported
    }
}

@MainActor
final class EventKitReminderStore: ReminderStore {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func authorizationStatus() -> ReminderAuthorization {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined:
            return .notDetermined
        case .authorized, .fullAccess:
            return .fullAccess
        case .denied, .restricted, .writeOnly:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestFullAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToReminders()
    }

    func writableLists() -> [ReminderList] {
        eventStore.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .map {
                ReminderList(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source.title
                )
            }
    }

    func defaultListIdentifier() -> String? {
        let calendar = eventStore.defaultCalendarForNewReminders()
        guard calendar?.allowsContentModifications == true else { return nil }
        return calendar?.calendarIdentifier
    }

    func createReminder(
        title: String,
        isCompleted: Bool,
        listIdentifier: String,
        taskIdentifier: UUID
    ) async throws -> String {
        try await createReminder(
            title: title, isCompleted: isCompleted, dueDate: nil,
            listIdentifier: listIdentifier, taskIdentifier: taskIdentifier
        )
    }

    func createReminder(
        title: String,
        isCompleted: Bool,
        dueDate: TaskDueDate?,
        listIdentifier: String,
        taskIdentifier: UUID
    ) async throws -> String {
        try await createReminder(
            title: title, isCompleted: isCompleted, dueDate: dueDate,
            alarmOffsetMinutes: nil, listIdentifier: listIdentifier,
            taskIdentifier: taskIdentifier
        )
    }

    func createReminder(
        title: String,
        isCompleted: Bool,
        dueDate: TaskDueDate?,
        alarmOffsetMinutes: Int?,
        listIdentifier: String,
        taskIdentifier: UUID
    ) async throws -> String {
        let alarmDate = try Self.alarmDate(for: dueDate, offsetMinutes: alarmOffsetMinutes)
        guard let calendar = eventStore.calendar(withIdentifier: listIdentifier),
              calendar.allowsContentModifications else {
            throw ReminderServiceError.selectedListUnavailable
        }

        let marker = Self.marker(for: taskIdentifier)
        // Search every reminder calendar before creating in the selected one. A
        // user may switch lists while an interrupted create is being recovered.
        let reminders = try await reminders(in: nil)
        if let existing = reminders.first(where: { reminder in
            reminder.url?.absoluteString == marker.absoluteString
                || reminder.notes?.contains(marker.absoluteString) == true
        }) {
            return existing.calendarItemIdentifier
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.isCompleted = isCompleted
        Self.setDueDate(dueDate, on: reminder)
        if let alarmDate {
            reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
        }
        reminder.url = marker

        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw ReminderServiceError.saveFailed(error.localizedDescription)
        }
        return reminder.calendarItemIdentifier
    }

    func setReminderCompleted(identifier: String, isCompleted: Bool) async throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound
        }
        guard reminder.calendar.allowsContentModifications else {
            throw ReminderServiceError.selectedListUnavailable
        }
        reminder.isCompleted = isCompleted
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw ReminderServiceError.saveFailed(error.localizedDescription)
        }
    }

    func setReminderDueDate(identifier: String, dueDate: TaskDueDate?) async throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound
        }
        guard reminder.calendar.allowsContentModifications else {
            throw ReminderServiceError.selectedListUnavailable
        }
        Self.setDueDate(dueDate, on: reminder)
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw ReminderServiceError.saveFailed(error.localizedDescription)
        }
    }

    func setReminderSchedule(
        identifier: String, dueDate: TaskDueDate?, alarmOffsetMinutes: Int?,
        previousAlarmOffsetMinutes: Int?
    ) async throws {
        let newAlarmDate = try Self.alarmDate(
            for: dueDate, offsetMinutes: alarmOffsetMinutes
        )
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound
        }
        guard reminder.calendar.allowsContentModifications else {
            throw ReminderServiceError.selectedListUnavailable
        }

        // EventKit exposes no alarm identifier. Only replace an alarm whose
        // absolute time uniquely matches the last app-synced offset and due time.
        let oldDueDate = reminder.dueDateComponents.flatMap(Self.taskDueDate)
        if let oldDueDate, oldDueDate.hasTime, let previousAlarmOffsetMinutes,
           let oldAlarmDate = try Self.alarmDate(
               for: oldDueDate, offsetMinutes: previousAlarmOffsetMinutes
           ) {
            let matching = Self.alarms(on: reminder).filter {
                $0.absoluteDate == oldAlarmDate
            }
            if matching.count == 1, let ownedAlarm = matching.first {
                reminder.removeAlarm(ownedAlarm)
            }
        }

        Self.setDueDate(dueDate, on: reminder)
        if let newAlarmDate,
           !Self.alarms(on: reminder).contains(where: {
               $0.absoluteDate == newAlarmDate
           }) {
            reminder.addAlarm(EKAlarm(absoluteDate: newAlarmDate))
        }
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw ReminderServiceError.saveFailed(error.localizedDescription)
        }
    }

    func removeReminder(
        identifier: String, taskIdentifier: UUID, calendarIdentifier: String?
    ) async throws -> Bool {
        let marker = Self.marker(for: taskIdentifier).absoluteString
        let calendars = eventStore.calendars(for: .reminder)
        guard !calendars.isEmpty else { throw ReminderServiceError.fetchFailed }
        if let calendarIdentifier,
           !calendars.contains(where: { $0.calendarIdentifier == calendarIdentifier }) {
            throw ReminderServiceError.originalListUnavailable
        }
        let fetched = try await reminders(in: calendars)
        guard authorizationStatus() == .fullAccess else { throw ReminderServiceError.noAccess }
        let target = fetched.first {
            $0.url?.absoluteString == marker || $0.notes?.contains(marker) == true
        }
        if target == nil,
           fetched.contains(where: { $0.calendarItemIdentifier == identifier }) {
            // A recycled identifier may now name an unrelated reminder. Deletion
            // requires the stable task marker, including for a moved reminder.
            throw ReminderServiceError.reminderNotFound
        }
        guard let target else { return false } // An interrupted earlier delete already finished.
        guard target.calendar.allowsContentModifications else {
            throw ReminderServiceError.selectedListUnavailable
        }
        do {
            try eventStore.remove(target, commit: true)
        } catch {
            throw ReminderServiceError.saveFailed(error.localizedDescription)
        }
        return true
    }

    func fetchReminderRecords(
        for requests: [ReminderLookupRequest]
    ) async throws -> ReminderReadSnapshot {
        let calendars = eventStore.calendars(for: .reminder)
        let readableBeforeFetch = Set(calendars.map(\.calendarIdentifier))
        guard !calendars.isEmpty else {
            return ReminderReadSnapshot(
                recordsByTaskIdentifier: [:],
                readableCalendarIdentifiers: readableBeforeFetch
            )
        }

        let fetched = try await reminders(in: calendars)
        guard authorizationStatus() == .fullAccess else {
            throw ReminderServiceError.noAccess
        }
        let readableAfterFetch = Set(
            eventStore.calendars(for: .reminder).map(\.calendarIdentifier)
        )
        let readableCalendarIdentifiers = readableBeforeFetch.intersection(readableAfterFetch)
        let remindersByIdentifier = Dictionary(
            fetched.map { ($0.calendarItemIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let remindersByMarker = Dictionary(
            fetched.compactMap { reminder -> (String, EKReminder)? in
                guard let marker = reminder.url?.absoluteString else { return nil }
                return (marker, reminder)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var records: [UUID: ReminderRecord] = [:]
        for request in requests {
            let marker = Self.marker(for: request.taskIdentifier).absoluteString
            let byIdentifier = request.reminderIdentifier
                .flatMap { remindersByIdentifier[$0] }
                .flatMap { reminder in
                    Self.hasDifferentTaskMarker(reminder, expectedMarker: marker)
                        ? nil
                        : reminder
                }
            // Prefer the task marker. Calendar item identifiers can change and a
            // stale identifier must never attach a task to an unrelated reminder.
            let reminder = remindersByMarker[marker]
                ?? fetched.first(where: { $0.notes?.contains(marker) == true })
                ?? byIdentifier
            guard let reminder else { continue }
            records[request.taskIdentifier] = ReminderRecord(
                taskIdentifier: request.taskIdentifier,
                reminderIdentifier: reminder.calendarItemIdentifier,
                calendarIdentifier: reminder.calendar.calendarIdentifier,
                isCompleted: reminder.isCompleted,
                dueDate: reminder.dueDateComponents.flatMap(Self.taskDueDate),
                alarmOffsetMinutes: Self.readAlarmOffset(from: reminder)
            )
        }
        return ReminderReadSnapshot(
            recordsByTaskIdentifier: records,
            readableCalendarIdentifiers: readableCalendarIdentifiers
        )
    }

    private func reminders(in calendars: [EKCalendar]?) async throws -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: calendars)
        return try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: ReminderServiceError.fetchFailed)
                    return
                }
                continuation.resume(returning: reminders)
            }
        }
    }

    private static func marker(for taskIdentifier: UUID) -> URL {
        // The marker makes an interrupted create recoverable without touching the
        // user's reminder title and prevents repeated taps from creating duplicates.
        URL(string: "notizzettel://recognized-task/\(taskIdentifier.uuidString.lowercased())")!
    }

    private static func dueDateComponents(_ dueDate: TaskDueDate) -> DateComponents {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = dueDate.year
        components.month = dueDate.month
        components.day = dueDate.day
        components.hour = dueDate.hour
        components.minute = dueDate.minute
        return components
    }

    private static func setDueDate(_ dueDate: TaskDueDate?, on reminder: EKReminder) {
        let components = dueDate.map(dueDateComponents)
        reminder.dueDateComponents = components
        // Timed reminders need a start date for EventKit to keep the clock time.
        // Clear it again for all-day reminders, including after a timed edit.
        reminder.startDateComponents = dueDate?.hasTime == true ? components : nil
    }

    private static func taskDueDate(from components: DateComponents) -> TaskDueDate? {
        guard let year = components.year, let month = components.month,
              let day = components.day,
              TaskDueDate.isValid(year: year, month: month, day: day,
                                  hour: components.hour, minute: components.minute)
        else { return nil }
        return TaskDueDate(
            year: year, month: month, day: day,
            hour: components.hour, minute: components.minute
        )
    }

    private static func alarmDate(
        for dueDate: TaskDueDate?, offsetMinutes: Int?
    ) throws -> Date? {
        guard let offsetMinutes else { return nil }
        guard let dueDate, dueDate.hasTime, [0, 15, 60].contains(offsetMinutes) else {
            throw ReminderServiceError.alarmRequiresTimedDueDate
        }
        return dueDate.date.addingTimeInterval(TimeInterval(-offsetMinutes * 60))
    }

    private static func readAlarmOffset(from reminder: EKReminder) -> Int? {
        guard let dueDate = reminder.dueDateComponents.flatMap(taskDueDate),
              dueDate.hasTime else { return nil }
        let offsets = [0, 15, 60].filter { offset in
            let alarmDate = dueDate.date.addingTimeInterval(TimeInterval(-offset * 60))
            return alarms(on: reminder).contains(where: {
                $0.absoluteDate == alarmDate
            })
        }
        return offsets.count == 1 ? offsets.first : nil
    }

    private static func alarms(on reminder: EKReminder) -> [EKAlarm] {
        reminder.alarms.flatMap { $0 } ?? []
    }

    private static func hasDifferentTaskMarker(
        _ reminder: EKReminder,
        expectedMarker: String
    ) -> Bool {
        if let url = reminder.url?.absoluteString,
           url.hasPrefix("notizzettel://recognized-task/") {
            return url != expectedMarker
        }
        if let notes = reminder.notes,
           let markerRange = notes.range(of: "notizzettel://recognized-task/") {
            let markerTail = notes[markerRange.lowerBound...]
            let embeddedMarker = markerTail.prefix { !$0.isWhitespace }
            return String(embeddedMarker) != expectedMarker
        }
        return false
    }
}

@MainActor
final class ReminderService: ObservableObject {
    @Published private(set) var lists: [ReminderList] = []
    @Published private(set) var selectedListID: String
    @Published private(set) var hasAccess = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var automaticallyCreateReminders: Bool
    @Published private(set) var statusRevision = 0

    private static let selectedListDefaultsKey = "selectedReminderListID"
    private static let automaticCreationDefaultsKey = "automaticallyCreateReminders"

    private let store: any ReminderStore
    private let userDefaults: UserDefaults
    private var selectionWasInitialized: Bool
    private var creationTasks: [UUID: Task<String, Error>] = [:]
    private var eventStoreChangeCancellable: AnyCancellable?

    init(
        store: (any ReminderStore)? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.store = store ?? EventKitReminderStore()
        self.userDefaults = userDefaults
        selectionWasInitialized = userDefaults.object(
            forKey: Self.selectedListDefaultsKey
        ) != nil
        selectedListID = userDefaults.string(forKey: Self.selectedListDefaultsKey) ?? ""
        automaticallyCreateReminders = userDefaults.bool(
            forKey: Self.automaticCreationDefaultsKey
        )
        refresh()
        eventStoreChangeCancellable = NotificationCenter.default.publisher(
            for: .EKEventStoreChanged
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    var selectedListTitle: String? {
        lists.first(where: { $0.id == selectedListID })?.title
    }

    func refresh() {
        statusRevision &+= 1
        let authorization = store.authorizationStatus()
        hasAccess = authorization == .fullAccess
        guard hasAccess else {
            lists = []
            if authorization == .denied {
                errorMessage = ReminderServiceError.noAccess.localizedDescription
            }
            return
        }

        errorMessage = nil
        lists = store.writableLists().sorted {
            if $0.sourceTitle == $1.sourceTitle {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.sourceTitle.localizedStandardCompare($1.sourceTitle) == .orderedAscending
        }

        if !selectedListID.isEmpty {
            guard lists.contains(where: { $0.id == selectedListID }) else {
                selectedListID = ""
                persistSelection()
                errorMessage = ReminderServiceError.selectedListUnavailable.localizedDescription
                return
            }
            errorMessage = nil
            return
        }

        guard !selectionWasInitialized else { return }
        selectionWasInitialized = true
        if let defaultID = store.defaultListIdentifier(),
           lists.contains(where: { $0.id == defaultID }) {
            selectedListID = defaultID
        }
        persistSelection()
    }

    func requestAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        errorMessage = nil
        defer { isRequestingAccess = false }

        do {
            let granted = try await store.requestFullAccess()
            refresh()
            if !granted || !hasAccess {
                errorMessage = ReminderServiceError.noAccess.localizedDescription
            }
        } catch {
            errorMessage = Self.message(for: error)
            refreshAuthorizationAndListsPreservingError()
        }
    }

    func selectList(_ id: String) {
        guard lists.contains(where: { $0.id == id }) else {
            selectedListID = ""
            selectionWasInitialized = true
            persistSelection()
            errorMessage = ReminderServiceError.selectedListUnavailable.localizedDescription
            return
        }
        selectedListID = id
        selectionWasInitialized = true
        persistSelection()
        errorMessage = nil
    }

    func setAutomaticCreation(_ enabled: Bool) {
        automaticallyCreateReminders = enabled
        userDefaults.set(enabled, forKey: Self.automaticCreationDefaultsKey)
    }

    func createReminder(
        title: String,
        isCompleted: Bool,
        taskID: UUID,
        dueDate: TaskDueDate? = nil,
        alarmOffsetMinutes: Int? = nil,
        preferredListIdentifier: String? = nil
    ) async throws -> String {
        guard store.authorizationStatus() == .fullAccess else {
            throw ReminderServiceError.noAccess
        }
        let writableLists = store.writableLists()
        let targetListIdentifier: String
        if let preferredListIdentifier {
            guard writableLists.contains(where: { $0.id == preferredListIdentifier }) else {
                throw ReminderServiceError.originalListUnavailable
            }
            targetListIdentifier = preferredListIdentifier
        } else {
            targetListIdentifier = selectedListID
        }
        guard !targetListIdentifier.isEmpty else {
            throw ReminderServiceError.noSelectedList
        }
        guard writableLists.contains(where: { $0.id == targetListIdentifier }) else {
            if targetListIdentifier == selectedListID {
                selectedListID = ""
                selectionWasInitialized = true
                persistSelection()
                errorMessage = ReminderServiceError.selectedListUnavailable.localizedDescription
            }
            throw ReminderServiceError.selectedListUnavailable
        }
        if let existingTask = creationTasks[taskID] {
            return try await existingTask.value
        }

        let listIdentifier = targetListIdentifier
        let store = store
        let creationTask = Task { @MainActor in
            try await store.createReminder(
                title: title,
                isCompleted: isCompleted,
                dueDate: dueDate,
                alarmOffsetMinutes: alarmOffsetMinutes,
                listIdentifier: listIdentifier,
                taskIdentifier: taskID
            )
        }
        creationTasks[taskID] = creationTask
        defer { creationTasks[taskID] = nil }
        let identifier = try await creationTask.value
        statusRevision &+= 1
        return identifier
    }

    func updateReminderCompletion(identifier: String, isCompleted: Bool) async throws {
        guard store.authorizationStatus() == .fullAccess else {
            throw ReminderServiceError.noAccess
        }
        try await store.setReminderCompleted(identifier: identifier, isCompleted: isCompleted)
        statusRevision &+= 1
    }

    func updateReminderDueDate(identifier: String, dueDate: TaskDueDate?) async throws {
        guard store.authorizationStatus() == .fullAccess else {
            throw ReminderServiceError.noAccess
        }
        try await store.setReminderDueDate(identifier: identifier, dueDate: dueDate)
        statusRevision &+= 1
    }

    func updateReminderSchedule(
        identifier: String, dueDate: TaskDueDate?, alarmOffsetMinutes: Int?,
        previousAlarmOffsetMinutes: Int?
    ) async throws {
        guard store.authorizationStatus() == .fullAccess else {
            throw ReminderServiceError.noAccess
        }
        try await store.setReminderSchedule(
            identifier: identifier, dueDate: dueDate,
            alarmOffsetMinutes: alarmOffsetMinutes,
            previousAlarmOffsetMinutes: previousAlarmOffsetMinutes
        )
        statusRevision &+= 1
    }

    func removeReminder(
        identifier: String, taskID: UUID, calendarIdentifier: String?
    ) async throws -> Bool {
        guard store.authorizationStatus() == .fullAccess else {
            throw ReminderServiceError.noAccess
        }
        let removed = try await store.removeReminder(
            identifier: identifier, taskIdentifier: taskID,
            calendarIdentifier: calendarIdentifier
        )
        statusRevision &+= 1
        return removed
    }

    func fetchReminderRecords(
        for requests: [ReminderLookupRequest]
    ) async throws -> ReminderReadSnapshot {
        guard store.authorizationStatus() == .fullAccess else {
            throw ReminderServiceError.noAccess
        }
        let snapshot = try await store.fetchReminderRecords(for: requests)
        guard store.authorizationStatus() == .fullAccess else {
            throw ReminderServiceError.noAccess
        }
        return snapshot
    }

    private func persistSelection() {
        userDefaults.set(selectedListID, forKey: Self.selectedListDefaultsKey)
    }

    private func refreshAuthorizationAndListsPreservingError() {
        let message = errorMessage
        refresh()
        errorMessage = message
    }

    private static func message(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}
