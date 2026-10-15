import CloudKit
import PencilKit
import XCTest

@testable import Notizen

@MainActor
final class CloudReminderLifecycleTests: XCTestCase {
    func testRemoteRemovalQueuesLocalDeleteAndRepeatedImportPreservesIntent() throws {
        let local = task(status: .open)
        var remote = local
        remote.isPresent = false
        remote.wasRemovedFromDrawing = true
        let first = try importing(remote, over: local)
        XCTAssertTrue(first.reminderRemovalPending)
        XCTAssertTrue(first.reminderRestorePending)
        XCTAssertEqual(first.reminderIdentifier, "local-reminder")
        let repeated = try importing(remote, over: first)
        XCTAssertTrue(repeated.reminderRemovalPending)
        XCTAssertTrue(repeated.reminderRestorePending)
    }

    func testRemoteUndoPreservesDrawingDeletionProvenance() throws {
        var local = task(status: .deleted)
        local.isPresent = false
        local.wasRemovedFromDrawing = true
        local.reminderRestorePending = true
        var remote = local
        remote.isPresent = true
        remote.wasRemovedFromDrawing = false
        let restored = try importing(remote, over: local)
        XCTAssertFalse(restored.reminderRemovalPending)
        XCTAssertTrue(restored.reminderRestorePending)
        XCTAssertFalse(restored.wasRemovedFromDrawing)
    }

    func testRemoteEraseAndUndoNeverArmsRestoreForExternallyDeletedReminder() throws {
        let local = task(status: .deleted)
        var remote = local
        remote.isPresent = false
        remote.wasRemovedFromDrawing = true
        let removed = try importing(remote, over: local)
        XCTAssertFalse(removed.reminderRemovalPending)
        XCTAssertFalse(removed.reminderRestorePending)
        remote.isPresent = true
        remote.wasRemovedFromDrawing = false
        let restored = try importing(remote, over: removed)
        XCTAssertEqual(restored.reminderStatus, .deleted)
        XCTAssertFalse(restored.reminderRestorePending)
    }

    func testRemoteUndoCancelsPendingRemovalWithoutLosingRecoveryIntent() throws {
        var local = task(status: .open)
        local.wasRemovedFromDrawing = true
        local.reminderRemovalPending = true
        local.reminderRestorePending = true
        var remote = local
        remote.wasRemovedFromDrawing = false
        let restored = try importing(remote, over: local)
        XCTAssertFalse(restored.reminderRemovalPending)
        XCTAssertTrue(restored.reminderRestorePending)
    }

    private func task(status: TaskReminderStatus) -> RecognizedTask {
        RecognizedTask(id: UUID(), bounds: CGRect(x: 20, y: 20, width: 30, height: 30),
                       recognizedText: "Anrufen", correctedText: nil, confidence: 1,
                       isChecked: false, reminderIdentifier: "local-reminder",
                       reminderCalendarIdentifier: "local-list", reminderStatus: status)
    }

    private func importing(_ remote: RecognizedTask, over local: RecognizedTask) throws -> RecognizedTask {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = NoteStore(storageDirectory: directory.appendingPathComponent("source"))
        let note = try XCTUnwrap(source.createNote())
        source.saveDrawing(PKDrawing(), for: note.id)
        source.saveRecognizedTasks([remote], for: note.id)
        let zone = CKRecordZone.ID(zoneName: "LifecycleTests", ownerName: CKCurrentUserDefaultName)
        let record = try XCTUnwrap(source.cloudRecord(
            for: CKRecord.ID(recordName: "page-\(note.id.uuidString)", zoneID: zone), zoneID: zone))
        let receiver = NoteStore(storageDirectory: directory.appendingPathComponent("receiver"))
        let noteRecord = CKRecord(recordType: "Note", recordID: CKRecord.ID(
            recordName: "note-\(note.id.uuidString)", zoneID: zone))
        noteRecord["payload"] = try JSONEncoder().encode(note) as NSData
        try receiver.applyCloudRecord(noteRecord)
        receiver.saveRecognizedTasks([local], for: note.id)
        try receiver.applyCloudRecord(record)
        return try XCTUnwrap(receiver.recognizedTasks(for: note.id).first)
    }
}
