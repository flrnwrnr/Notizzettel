import CoreGraphics
import Foundation
import XCTest

@testable import Notizen

@MainActor
final class AutomaticReminderTests: XCTestCase {
    func testAutomaticCreationDefaultsToManualAndPersistsChanges() async throws {
        let store = AutomaticReminderStoreMock()
        let (service, defaults, suiteName) = makeService(store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(service.automaticallyCreateReminders)

        let session = makeSession(candidate: candidate())
        configure(session, service: service)
        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil { !session.tasks.isEmpty }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.createCalls, 0)

        service.setAutomaticCreation(true)
        let reloaded = ReminderService(store: store, userDefaults: defaults)
        XCTAssertTrue(reloaded.automaticallyCreateReminders)
    }

    func testEnablingAutomaticCreationSchedulesExistingProposal() async throws {
        let store = AutomaticReminderStoreMock()
        let (service, defaults, suiteName) = makeService(store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = makeSession(candidate: candidate())
        configure(session, service: service)

        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil { session.tasks.count == 1 }
        XCTAssertEqual(store.createCalls, 0)

        service.setAutomaticCreation(true)
        session.reminderPreferencesDidChange()
        try await waitUntil { session.tasks.first?.reminderIdentifier != nil }

        XCTAssertEqual(store.createCalls, 1)
    }

    func testDisablingAutomaticCreationBeforeStabilityDelayCancelsCreate() async throws {
        let store = AutomaticReminderStoreMock()
        let (service, defaults, suiteName) = makeService(store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        service.setAutomaticCreation(true)
        let session = makeSession(
            candidate: candidate(),
            autoCreationDelay: .milliseconds(100)
        )
        configure(session, service: service)

        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil { session.tasks.count == 1 }
        service.setAutomaticCreation(false)
        session.reminderPreferencesDidChange()
        try await Task.sleep(for: .milliseconds(140))

        XCTAssertEqual(store.createCalls, 0)
        XCTAssertNil(session.tasks.first?.reminderIdentifier)
    }

    func testEmptyAndLowConfidenceTitlesAreNotCreatedAutomatically() async throws {
        let store = AutomaticReminderStoreMock()
        let (service, defaults, suiteName) = makeService(store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        service.setAutomaticCreation(true)
        let empty = candidate(text: "   ", confidence: 0.95, y: 20)
        let unreadable = candidate(text: "Vielleicht", confidence: 0.64, y: 80)
        let session = TaskRecognitionSession(
            debounceDuration: .zero,
            autoCreationDelay: .zero
        ) { _ in [empty, unreadable] }
        configure(session, service: service)

        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil { session.tasks.count == 2 }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.createCalls, 0)
    }

    func testManualCorrectionMakesLowConfidenceTaskEligible() async throws {
        let store = AutomaticReminderStoreMock()
        let (service, defaults, suiteName) = makeService(store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        service.setAutomaticCreation(true)
        let bounds = CGRect(x: 20, y: 20, width: 32, height: 32)
        let saved = RecognizedTask(
            id: UUID(),
            bounds: bounds,
            recognizedText: "?",
            correctedText: "Milch kaufen",
            confidence: 0.2,
            isChecked: false
        )
        let session = TaskRecognitionSession(
            debounceDuration: .zero,
            autoCreationDelay: .zero
        ) { _ in
            [TaskCandidate(bounds: bounds, text: "?", confidence: 0.2, isChecked: false)]
        }
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [saved]) { _, _ in }

        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil { session.tasks.first?.reminderIdentifier != nil }

        XCTAssertEqual(store.createdTitles, ["Milch kaufen"])
    }

    func testRepeatedRecognitionDoesNotDuplicateAutomaticallyCreatedReminder() async throws {
        let store = AutomaticReminderStoreMock()
        let (service, defaults, suiteName) = makeService(store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        service.setAutomaticCreation(true)
        let proposal = candidate()
        let session = makeSession(candidate: proposal)
        configure(session, service: service)

        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil { session.tasks.first?.reminderIdentifier != nil }
        session.drawingDidChange(Data([2]), automatically: false)
        try await waitUntil { !session.isAnalyzing }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.createCalls, 1)
    }

    func testFinishingPendingRecognitionFlushesLinkedCheckboxBeforeDebounce() async {
        let store = AutomaticReminderStoreMock()
        let (service, defaults, suiteName) = makeService(store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bounds = CGRect(x: 20, y: 20, width: 32, height: 32)
        let linked = RecognizedTask(
            id: UUID(),
            bounds: bounds,
            recognizedText: "Milch kaufen",
            correctedText: nil,
            confidence: 0.9,
            isChecked: false,
            reminderIdentifier: "linked-reminder",
            reminderLastSyncedIsChecked: false
        )
        let session = TaskRecognitionSession(
            debounceDuration: .seconds(10),
            autoCreationDelay: .zero
        ) { _ in
            [TaskCandidate(bounds: bounds, text: "Milch kaufen", confidence: 0.9, isChecked: true)]
        }
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: [linked]) { _, _ in }

        session.drawingDidChange(Data([1]))
        await session.finishPendingRecognition()

        XCTAssertEqual(store.completionUpdates.count, 1)
        XCTAssertEqual(store.completionUpdates.first?.identifier, "linked-reminder")
        XCTAssertEqual(store.completionUpdates.first?.isCompleted, true)
    }

    func testLeavingWithPendingAutomaticCreationWaitsForStableCreate() async throws {
        let store = AutomaticReminderStoreMock()
        let (service, defaults, suiteName) = makeService(store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        service.setAutomaticCreation(true)
        let session = makeSession(
            candidate: candidate(),
            autoCreationDelay: .milliseconds(30)
        )
        configure(session, service: service)

        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil { session.tasks.count == 1 }
        await session.finishPendingRecognition()

        XCTAssertEqual(store.createCalls, 1)
        XCTAssertNotNil(session.tasks.first?.reminderIdentifier)
    }

    func testPreferenceRefreshDuringFinishIsRescheduledAfterSuppression() async throws {
        let store = AutomaticReminderStoreMock()
        let (service, defaults, suiteName) = makeService(store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        service.setAutomaticCreation(true)
        let gate = AutomaticRecognitionGate()
        let proposal = candidate()
        let session = TaskRecognitionSession(
            debounceDuration: .seconds(10),
            autoCreationDelay: .zero
        ) { _ in
            await gate.recognize()
        }
        configure(session, service: service)
        session.drawingDidChange(Data([1]))

        let finish = Task { await session.finishPendingRecognition() }
        try await waitUntil { gate.didStart }
        // This mirrors returning active while the inactive/background flush is
        // still awaiting recognition.
        session.reminderPreferencesDidChange()
        gate.resume(with: [proposal])
        await finish.value

        XCTAssertEqual(store.createCalls, 1)
        XCTAssertNotNil(session.tasks.first?.reminderIdentifier)
    }

    func testResultDuringStrokeCreatesReminderOnlyAfterToolEndsWithoutAnotherRun() async throws {
        let store = AutomaticReminderStoreMock()
        let (service, defaults, suiteName) = makeService(store: store)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        service.setAutomaticCreation(true)
        let gate = AutomaticRecognitionGate()
        let session = TaskRecognitionSession(
            debounceDuration: .zero,
            autoCreationDelay: .zero
        ) { _ in await gate.recognize() }
        configure(session, service: service)
        var persistedCount = 0
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in persistedCount += 1 }

        session.drawingActivityBegan()
        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil { gate.didStart }
        gate.resume(with: [candidate()])
        try await waitUntil { !session.isAnalyzing }
        session.reminderPreferencesDidChange()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(session.tasks.isEmpty)
        XCTAssertEqual(persistedCount, 0)
        XCTAssertEqual(store.createCalls, 0)

        // The result is still valid at tool-up: reuse it rather than starting
        // another recognition, whose gate would remain suspended in this test.
        session.drawingActivityEnded(Data([1]))
        try await waitUntil { session.tasks.first?.reminderIdentifier != nil }
        XCTAssertEqual(store.createCalls, 1)
        XCTAssertGreaterThan(persistedCount, 0)
        session.deactivate()
    }

    private func makeSession(
        candidate: TaskCandidate,
        autoCreationDelay: Duration = .zero
    ) -> TaskRecognitionSession {
        TaskRecognitionSession(
            debounceDuration: .zero,
            autoCreationDelay: autoCreationDelay
        ) { _ in [candidate] }
    }

    private func configure(_ session: TaskRecognitionSession, service: ReminderService) {
        session.configureReminders(service)
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in }
    }

    private func candidate(
        text: String = "Milch kaufen",
        confidence: Float = 0.9,
        y: CGFloat = 20
    ) -> TaskCandidate {
        TaskCandidate(
            bounds: CGRect(x: 20, y: y, width: 32, height: 32),
            text: text,
            confidence: confidence,
            isChecked: false
        )
    }

    private func makeService(
        store: AutomaticReminderStoreMock
    ) -> (ReminderService, UserDefaults, String) {
        let suiteName = "AutomaticReminderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (ReminderService(store: store, userDefaults: defaults), defaults, suiteName)
    }

    private func waitUntil(
        attempts: Int = 200,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for automatic reminder operation")
    }
}

@MainActor
private final class AutomaticRecognitionGate {
    private(set) var didStart = false
    private var continuation: CheckedContinuation<[TaskCandidate], Never>?

    func recognize() async -> [TaskCandidate] {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with candidates: [TaskCandidate]) {
        continuation?.resume(returning: candidates)
        continuation = nil
    }
}

@MainActor
private final class AutomaticReminderStoreMock: ReminderStore {
    struct CompletionUpdate: Equatable {
        let identifier: String
        let isCompleted: Bool
    }

    var authorization: ReminderAuthorization = .fullAccess
    var lists = [ReminderList(id: "list-1", title: "Notizen", sourceTitle: "iCloud")]
    var createCalls = 0
    var createdTitles: [String] = []
    var completionUpdates: [CompletionUpdate] = []

    func authorizationStatus() -> ReminderAuthorization { authorization }

    func requestFullAccess() async throws -> Bool {
        authorization = .fullAccess
        return true
    }

    func writableLists() -> [ReminderList] { lists }

    func defaultListIdentifier() -> String? { lists.first?.id }

    func createReminder(
        title: String,
        isCompleted: Bool,
        listIdentifier: String,
        taskIdentifier: UUID
    ) async throws -> String {
        createCalls += 1
        createdTitles.append(title)
        return "reminder-\(taskIdentifier.uuidString)"
    }

    func setReminderCompleted(identifier: String, isCompleted: Bool) async throws {
        completionUpdates.append(
            CompletionUpdate(identifier: identifier, isCompleted: isCompleted)
        )
    }
}
