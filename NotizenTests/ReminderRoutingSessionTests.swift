import CoreGraphics
import Foundation
import XCTest

@testable import Notizen

@MainActor
final class ReminderRoutingSessionTests: XCTestCase {
    func testDestinationSelectionPausesCreationUntilDismissed() async throws {
        let store = RoutingReminderStore()
        let service = makeService(store: store)
        service.setAutomaticCreation(true)
        let task = makeTask()
        let session = TaskRecognitionSession(autoCreationDelay: .milliseconds(10))
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }
        session.configureReminderRouting { _ in
            ReminderRoutingDecision(targetListID: "customer", suggestedListID: "customer", requiresConfirmation: false, reason: nil)
        }
        session.beginDestinationSelection()
        session.reminderPreferencesDidChange()
        await session.createReminder(for: task.id)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(store.creationLists.isEmpty)
        session.endDestinationSelection()
        try await waitUntil { !store.creationLists.isEmpty }
        XCTAssertEqual(store.creationLists, ["customer"])
    }

    func testCustomerRouteWorksWithoutGlobalListAndKeepsBatchContext() async throws {
        let store = RoutingReminderStore()
        let service = makeService(store: store)
        service.selectList("unavailable")
        service.setAutomaticCreation(true)
        let tasks = [makeTask(), makeTask()]
        let session = TaskRecognitionSession(autoCreationDelay: .milliseconds(10))
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: tasks) { _, _ in }
        session.configureReminderRouting { titles in
            ReminderRoutingDecision(targetListID: titles.count == 2 ? "customer" : nil, suggestedListID: "customer", requiresConfirmation: titles.count != 2, reason: nil)
        }
        try await waitUntil { session.tasks.allSatisfy { $0.reminderIdentifier != nil } }
        XCTAssertEqual(store.creationLists, ["customer", "customer"])
    }

    func testUnconfirmedRouteBlocksManualAndAutomaticCreation() async throws {
        let store = RoutingReminderStore()
        let service = makeService(store: store)
        service.setAutomaticCreation(true)
        let task = makeTask()
        let session = TaskRecognitionSession(autoCreationDelay: .milliseconds(10))
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }
        session.configureReminderRouting { _ in
            ReminderRoutingDecision(
                targetListID: nil,
                suggestedListID: "customer",
                requiresConfirmation: true,
                reason: "Liste bestätigen"
            )
        }

        await session.createReminder(for: task.id)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(store.creationLists, [])
        XCTAssertNil(session.tasks.first?.reminderIdentifier)
        XCTAssertEqual(session.routingDecision?.suggestedListID, "customer")
    }

    func testConfirmedRouteCreatesInCustomerListAndPersistsLink() async throws {
        let store = RoutingReminderStore()
        let service = makeService(store: store)
        let task = makeTask()
        let session = TaskRecognitionSession()
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }
        session.configureReminderRouting { _ in
            ReminderRoutingDecision(
                targetListID: "customer",
                suggestedListID: "customer",
                requiresConfirmation: false,
                reason: nil
            )
        }

        await session.createReminder(for: task.id)

        XCTAssertEqual(store.creationLists, ["customer"])
        XCTAssertEqual(session.tasks.first?.reminderIdentifier, "created-\(task.id.uuidString)")
        XCTAssertEqual(session.tasks.first?.reminderCalendarIdentifier, "customer")
    }

    func testTitleCorrectionRefreshesRouteAndReschedulesAutomaticCreation() async throws {
        let store = RoutingReminderStore()
        let service = makeService(store: store)
        service.setAutomaticCreation(true)
        let task = makeTask()
        let session = TaskRecognitionSession(autoCreationDelay: .milliseconds(20))
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [task]) { _, _ in }
        session.configureReminderRouting { titles in
            if titles.contains(where: { $0.contains("Umbau") }) {
                return ReminderRoutingDecision(
                    targetListID: "customer",
                    suggestedListID: "customer",
                    requiresConfirmation: false,
                    reason: nil
                )
            }
            return ReminderRoutingDecision(
                targetListID: nil,
                suggestedListID: "customer",
                requiresConfirmation: true,
                reason: nil
            )
        }

        session.updateTitle("Umbau prüfen", for: task.id)
        try await waitUntil { session.tasks.first?.reminderIdentifier != nil }

        XCTAssertEqual(store.creationLists, ["customer"])
        XCTAssertEqual(session.routingDecision?.targetListID, "customer")
    }

    func testDeactivateClearsRoutingProviderBeforeNextNote() async {
        let store = RoutingReminderStore()
        let service = makeService(store: store)
        let first = makeTask()
        let second = makeTask()
        let session = TaskRecognitionSession()
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [first]) { _, _ in }
        session.configureReminderRouting { _ in
            ReminderRoutingDecision(
                targetListID: nil,
                suggestedListID: nil,
                requiresConfirmation: true,
                reason: nil
            )
        }
        session.deactivate()
        session.configure(noteID: UUID(), savedTasks: [second]) { _, _ in }

        await session.createReminder(for: second.id)

        XCTAssertNil(session.routingDecision)
        XCTAssertEqual(store.creationLists, ["global"])
    }

    private func makeTask() -> RecognizedTask {
        RecognizedTask(
            id: UUID(),
            bounds: CGRect(x: 20, y: 20, width: 32, height: 32),
            recognizedText: "Prüfen",
            correctedText: nil,
            confidence: 0.9,
            isChecked: false
        )
    }

    private func makeService(store: RoutingReminderStore) -> ReminderService {
        let suite = "ReminderRoutingSessionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ReminderService(store: store, userDefaults: defaults)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for routed reminder")
    }
}

@MainActor
private final class RoutingReminderStore: ReminderStore {
    var creationLists: [String] = []
    private var records: [UUID: ReminderRecord] = [:]

    func authorizationStatus() -> ReminderAuthorization { .fullAccess }
    func requestFullAccess() async throws -> Bool { true }
    func writableLists() -> [ReminderList] {
        [
            ReminderList(id: "global", title: "Allgemein", sourceTitle: "iCloud"),
            ReminderList(id: "customer", title: "Kunde", sourceTitle: "iCloud")
        ]
    }
    func defaultListIdentifier() -> String? { "global" }

    func createReminder(
        title: String,
        isCompleted: Bool,
        listIdentifier: String,
        taskIdentifier: UUID
    ) async throws -> String {
        creationLists.append(listIdentifier)
        let identifier = "created-\(taskIdentifier.uuidString)"
        records[taskIdentifier] = ReminderRecord(
            taskIdentifier: taskIdentifier,
            reminderIdentifier: identifier,
            calendarIdentifier: listIdentifier,
            isCompleted: isCompleted
        )
        return identifier
    }

    func setReminderCompleted(identifier: String, isCompleted: Bool) async throws {}

    func fetchReminderRecords(
        for requests: [ReminderLookupRequest]
    ) async throws -> ReminderReadSnapshot {
        ReminderReadSnapshot(
            recordsByTaskIdentifier: Dictionary(
                uniqueKeysWithValues: requests.compactMap { request in
                    records[request.taskIdentifier].map { (request.taskIdentifier, $0) }
                }
            ),
            readableCalendarIdentifiers: ["global", "customer"]
        )
    }
}
