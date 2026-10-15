import CoreGraphics
import XCTest
@testable import Notizen

final class TaskOverviewProjectionTests: XCTestCase {
    func testRemovedReminderTombstoneOnlyNeedsAttentionUntilSynchronized() {
        var task = sampleTask()
        task.reminderIdentifier = "linked"
        task.isPresent = false
        task.wasRemovedFromDrawing = true
        task.reminderStatus = .deleted

        XCTAssertEqual(TaskOverviewProjection.category(for: task), .hidden)
        XCTAssertFalse(TaskOverviewProjection.needsAction(task))

        task.reminderRemovalPending = true
        XCTAssertEqual(TaskOverviewProjection.category(for: task), .attention)
        XCTAssertTrue(TaskOverviewProjection.needsAction(task))

        task.reminderRemovalPending = false
        task.reminderSyncError = "Retry needed"
        XCTAssertEqual(TaskOverviewProjection.category(for: task), .attention)
    }

    func testIgnoredProposalDoesNotNeedActionOrBulkCreation() {
        var task = sampleTask()
        task.isIgnored = true
        XCTAssertEqual(TaskOverviewProjection.category(for: task), .ignored)
        XCTAssertFalse(TaskOverviewProjection.needsAction(task))
        XCTAssertFalse(TaskOverviewProjection.mayCreateInBulk(task, isProvisional: false))
    }

    func testProvisionalProposalCannotBeCreatedInBulk() {
        let task = sampleTask()
        XCTAssertEqual(TaskOverviewProjection.category(for: task), .proposal)
        XCTAssertFalse(TaskOverviewProjection.mayCreateInBulk(task, isProvisional: true))
        XCTAssertTrue(TaskOverviewProjection.mayCreateInBulk(task, isProvisional: false))
    }

    private func sampleTask() -> RecognizedTask {
        RecognizedTask(
            id: UUID(),
            bounds: CGRect(x: 20, y: 30, width: 20, height: 20),
            recognizedText: "Kundin anrufen",
            correctedText: nil,
            confidence: 0.9,
            isChecked: false
        )
    }
}
