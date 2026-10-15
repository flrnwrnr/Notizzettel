import CoreGraphics
import Foundation
import PencilKit
import XCTest

@testable import Notizen

@MainActor
final class RealCheckboxReminderSyncTests: XCTestCase {
    func testRealCheckedDrawingSynchronizesBothLinkedRemindersAndUncheckingReversesThem() async throws {
        let checkedDrawingData = try fixtureData(named: "PhoneTwoCheckedBoxes")
        let reminderStore = PipelineReminderStore()
        let reminderService = makeReminderService(store: reminderStore)
        let session = TaskRecognitionSession(debounceDuration: .zero)
        let savedTasks = linkedTasksFromCapturedNote()
        session.configureReminders(reminderService)
        session.configure(noteID: UUID(), savedTasks: savedTasks) { _, _ in }

        session.drawingDidChange(checkedDrawingData, automatically: false)
        await session.finishPendingRecognition()

        XCTAssertEqual(reminderStore.completionUpdates.count, 2)
        XCTAssertEqual(
            Set(reminderStore.completionUpdates),
            Set([
                .init(identifier: "linked-reminder-1", isCompleted: true),
                .init(identifier: "linked-reminder-2", isCompleted: true)
            ])
        )
        XCTAssertEqual(
            session.tasks.filter { $0.reminderIdentifier != nil }.map(\.isChecked),
            [true, true]
        )

        reminderStore.completionUpdates.removeAll()
        let checkedDrawing = try PKDrawing(data: checkedDrawingData)
        let tickStrokeIndices = Set([7, 17])
        let uncheckedDrawing = PKDrawing(
            strokes: checkedDrawing.strokes.enumerated().compactMap { index, stroke in
                tickStrokeIndices.contains(index) ? nil : stroke
            }
        )

        session.drawingDidChange(uncheckedDrawing.dataRepresentation(), automatically: false)
        await session.finishPendingRecognition()

        XCTAssertEqual(reminderStore.completionUpdates.count, 2)
        XCTAssertEqual(
            Set(reminderStore.completionUpdates),
            Set([
                .init(identifier: "linked-reminder-1", isCompleted: false),
                .init(identifier: "linked-reminder-2", isCompleted: false)
            ])
        )
        XCTAssertEqual(
            session.tasks.filter { $0.reminderIdentifier != nil }.map(\.isChecked),
            [false, false]
        )
    }

    private func linkedTasksFromCapturedNote() -> [RecognizedTask] {
        [
            RecognizedTask(
                id: UUID(uuidString: "2BA43948-5AF7-483E-9098-A0B65D9CA445")!,
                bounds: CGRect(
                    x: 54.507146606842674,
                    y: 51.490516662597656,
                    width: 71.50911163290343,
                    height: 61.788612365722656
                ),
                recognizedText: "Test",
                correctedText: nil,
                confidence: 1,
                isChecked: false,
                reminderIdentifier: "linked-reminder-1",
                reminderLastSyncedIsChecked: false
            ),
            RecognizedTask(
                id: UUID(uuidString: "40ED8A0D-FC2D-4574-A8A9-F4AAA3BA962B")!,
                bounds: CGRect(
                    x: 62.05961990356445,
                    y: 218.42817687988278,
                    width: 87.14258122444153,
                    height: 89.42110951741537
                ),
                recognizedText: "Tester",
                correctedText: nil,
                confidence: 1,
                isChecked: false,
                reminderIdentifier: "linked-reminder-2",
                reminderLastSyncedIsChecked: false
            )
        ]
    }

    private func makeReminderService(store: PipelineReminderStore) -> ReminderService {
        let suiteName = "RealCheckboxReminderSyncTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ReminderService(store: store, userDefaults: defaults)
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        )
        let fixture = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: url)
        )
        return try XCTUnwrap(Data(base64Encoded: fixture["drawing"] ?? ""))
    }
}

@MainActor
private final class PipelineReminderStore: ReminderStore {
    struct CompletionUpdate: Hashable {
        let identifier: String
        let isCompleted: Bool
    }

    var completionUpdates: [CompletionUpdate] = []

    func authorizationStatus() -> ReminderAuthorization { .fullAccess }

    func requestFullAccess() async throws -> Bool { true }

    func writableLists() -> [ReminderList] {
        [ReminderList(id: "test-list", title: "Tests", sourceTitle: "Test")]
    }

    func defaultListIdentifier() -> String? { "test-list" }

    func createReminder(
        title: String,
        isCompleted: Bool,
        listIdentifier: String,
        taskIdentifier: UUID
    ) async throws -> String {
        XCTFail("Linked tasks must not create replacement reminders")
        return "unexpected-reminder"
    }

    func setReminderCompleted(identifier: String, isCompleted: Bool) async throws {
        completionUpdates.append(
            CompletionUpdate(identifier: identifier, isCompleted: isCompleted)
        )
    }
}
