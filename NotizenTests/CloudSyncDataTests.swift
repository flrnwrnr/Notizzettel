import CloudKit
import Foundation
import PencilKit
import XCTest

@testable import Notizen

@MainActor
final class CloudSyncDataTests: XCTestCase {
    private var storageURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        storageURL = fileManager.temporaryDirectory
            .appendingPathComponent("CloudSyncDataTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
    }

    func testNoteCloudPayloadKeepsEventDescriptionAndOmitsDeviceIdentifiers() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let customer = try XCTUnwrap(store.createCustomer(name: "Acme"))
        let event = makeEvent()
        let note = try XCTUnwrap(store.createNote(customerID: customer.id, event: event))
        XCTAssertTrue(store.confirmReminderList("local-reminder-list", for: note.id, context: "test"))

        let zone = CKRecordZone.ID(zoneName: "Notizen", ownerName: CKCurrentUserDefaultName)
        let record = try XCTUnwrap(store.cloudRecord(
            for: CKRecord.ID(recordName: "note-\(note.id.uuidString)", zoneID: zone), zoneID: zone
        ))
        let payload = try XCTUnwrap(record["payload"] as? Data)
        let portable = try JSONDecoder().decode(Note.self, from: payload)
        let portableEvent = try XCTUnwrap(portable.calendarEvent)

        XCTAssertEqual(portable.id, note.id)
        XCTAssertEqual(portable.customerID, customer.id)
        XCTAssertNil(portable.reminderListID)
        XCTAssertNil(portableEvent.eventIdentifier)
        XCTAssertEqual(portableEvent.calendarIdentifier, "")
        XCTAssertEqual(portableEvent.id, note.id.uuidString)
        XCTAssertEqual(portableEvent.calendarTitle, event.calendarTitle)
        XCTAssertEqual(portableEvent.title, event.title)
        XCTAssertEqual(portableEvent.startDate, event.startDate)
        XCTAssertEqual(portableEvent.endDate, event.endDate)
        XCTAssertEqual(portableEvent.isAllDay, event.isAllDay)
    }

    func testImportedNoteRetainsMatchingLocalEventKitAndReminderIdentifiers() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let customer = try XCTUnwrap(store.createCustomer(name: "Acme"))
        let event = makeEvent()
        let local = try XCTUnwrap(store.createNote(customerID: customer.id, event: event))
        XCTAssertTrue(store.confirmReminderList("device-list-id", for: local.id, context: "test"))

        let remoteEvent = CalendarEventSnapshot(
            id: local.id.uuidString,
            eventIdentifier: nil,
            calendarIdentifier: "",
            calendarTitle: event.calendarTitle,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay
        )
        var remote = local
        remote.updatedAt = local.updatedAt.addingTimeInterval(60)
        remote.calendarEvent = remoteEvent
        remote.reminderListID = nil
        let record = CKRecord(
            recordType: "Note",
            recordID: CKRecord.ID(recordName: "note-\(local.id.uuidString)", zoneID: zoneID)
        )
        record["payload"] = try JSONEncoder().encode(remote) as NSData

        try store.applyCloudRecord(record)

        let imported = try XCTUnwrap(store.notes.first(where: { $0.id == local.id }))
        XCTAssertEqual(imported.reminderListID, "device-list-id")
        XCTAssertEqual(imported.calendarEvent, event)
        XCTAssertEqual(imported.updatedAt, remote.updatedAt)
    }

    func testCloudNoteWithMismatchedRecordIDDoesNotChangeLocalNotes() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let local = try XCTUnwrap(store.createNote())
        let before = store.notes
        let metadataURL = storageURL.appendingPathComponent("notes.json")
        let metadata = try Data(contentsOf: metadataURL)
        let record = CKRecord(recordType: "Note", recordID: CKRecord.ID(
            recordName: "note-\(UUID().uuidString)", zoneID: zoneID
        ))
        record["payload"] = try JSONEncoder().encode(local) as NSData

        XCTAssertThrowsError(try store.applyCloudRecord(record))
        XCTAssertEqual(store.notes, before)
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
    }

    func testCloudNoteWithDuplicatePageIDsDoesNotChangeLocalNotes() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let local = try XCTUnwrap(store.createNote())
        let before = store.notes
        let metadataURL = storageURL.appendingPathComponent("notes.json")
        let metadata = try Data(contentsOf: metadataURL)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(local)) as? [String: Any])
        payload["pageIDs"] = [local.id.uuidString, local.id.uuidString]
        let record = CKRecord(recordType: "Note", recordID: CKRecord.ID(
            recordName: "note-\(local.id.uuidString)", zoneID: zoneID
        ))
        record["payload"] = try JSONSerialization.data(withJSONObject: payload) as NSData

        XCTAssertThrowsError(try store.applyCloudRecord(record))
        XCTAssertEqual(store.notes, before)
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
    }

    func testCloudOrganizationWithDuplicateCustomersDoesNotChangeLocalCustomers() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let customer = try XCTUnwrap(store.createCustomer(name: "Local"))
        let before = store.customers
        let organizationURL = storageURL.appendingPathComponent("organization.json")
        let metadata = try Data(contentsOf: organizationURL)
        let duplicate = CloudCustomerPayload(id: customer.id, name: "Remote", isArchived: false)
        let record = CKRecord(recordType: "Organization", recordID: CKRecord.ID(
            recordName: "organization", zoneID: zoneID
        ))
        record["payload"] = try JSONEncoder().encode(CloudPayload(customers: [duplicate, duplicate])) as NSData

        XCTAssertThrowsError(try store.applyCloudRecord(record))
        XCTAssertEqual(store.customers, before)
        XCTAssertEqual(try Data(contentsOf: organizationURL), metadata)
    }

    func testDuplicateNoteIDsOnDiskFailWithoutOverwritingMetadata() throws {
        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let note = Note(id: UUID(), createdAt: Date(), updatedAt: Date())
        let metadataURL = storageURL.appendingPathComponent("notes.json")
        let metadata = try JSONEncoder().encode([note, note])
        try metadata.write(to: metadataURL, options: .atomic)

        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)

        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.createNote())
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
    }

    func testScheduledUploadClearsDelegateTaskLocalAndRunsOnMainActor() async {
        let probe = ScheduledUploadProbe()

        await SimulatedCloudKitDelegate.$isActive.withValue(true) {
            let task = CloudSyncCoordinator.scheduleUpload(delay: .zero) {
                probe.executed = true
                probe.inheritedDelegateContext = SimulatedCloudKitDelegate.isActive
                MainActor.preconditionIsolated()
                probe.ranOnMainActor = true
            }
            await task.value
        }

        XCTAssertTrue(probe.executed)
        XCTAssertFalse(probe.inheritedDelegateContext)
        XCTAssertTrue(probe.ranOnMainActor)
    }

    func testCancelledScheduledUploadDoesNotRunOperation() async {
        let probe = ScheduledUploadProbe()
        let task = CloudSyncCoordinator.scheduleUpload(delay: .seconds(1)) {
            probe.executed = true
        }

        task.cancel()
        await task.value

        XCTAssertFalse(probe.executed)
    }

    func testSyncCycleRunsForAlreadyCancelledCallerWithoutInheritingTaskLocal() async {
        let gate = CloudSyncCycleGate()
        let probe = CloudSyncCycleProbe()

        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await SimulatedCloudKitDelegate.$isActive.withValue(true) {
                await gate.joinOrStart {
                    probe.runCount += 1
                    probe.operationWasCancelled = Task.isCancelled
                    probe.inheritedDelegateContext = SimulatedCloudKitDelegate.isActive
                    MainActor.preconditionIsolated()
                }.value
            }
        }
        await caller.value

        XCTAssertEqual(probe.runCount, 1)
        XCTAssertFalse(probe.operationWasCancelled)
        XCTAssertFalse(probe.inheritedDelegateContext)
    }

    func testSyncCycleSurvivesCallerCancellationAndCoalescesRequests() async {
        let gate = CloudSyncCycleGate()
        let probe = CloudSyncCycleProbe()
        let started = expectation(description: "Sync cycle started")

        let caller = Task {
            await gate.joinOrStart {
                probe.runCount += 1
                started.fulfill()
                await probe.pause()
                probe.operationWasCancelled = Task.isCancelled
                probe.finished = true
            }.value
        }
        await fulfillment(of: [started], timeout: 1)

        caller.cancel()
        let joined = gate.joinOrStart { probe.runCount += 1 }
        probe.resume()
        await caller.value
        await joined.value

        XCTAssertEqual(probe.runCount, 1)
        XCTAssertFalse(probe.operationWasCancelled)
        XCTAssertTrue(probe.finished)

        await gate.joinOrStart { probe.runCount += 1 }.value
        XCTAssertEqual(probe.runCount, 2)
    }

    func testOrganizationMergeUsesCloudCustomerFieldsAndRetainsDeviceSettings() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let local = try XCTUnwrap(store.createCustomer(name: "Old name"))
        store.setCustomerReminderLists(local.id, defaultListID: "local-default", additionalListIDs: ["local-extra"])
        store.setCalendarCustomer("local-calendar", customerID: local.id)
        store.setAutomaticCustomerAssignment(true)

        let payload = try JSONEncoder().encode(CloudPayload(customers: [
            CloudCustomerPayload(id: local.id, name: "Cloud name", isArchived: true),
            CloudCustomerPayload(id: UUID(), name: "New customer", isArchived: false)
        ]))
        let record = CKRecord(recordType: "Organization", recordID: CKRecord.ID(recordName: "organization", zoneID: zoneID))
        record["payload"] = payload as NSData

        try store.applyCloudRecord(record, preserveLocalOrganization: true)

        let merged = try XCTUnwrap(store.customers.first(where: { $0.id == local.id }))
        XCTAssertEqual(merged.name, "Cloud name")
        XCTAssertTrue(merged.isArchived)
        XCTAssertEqual(merged.defaultReminderListID, "local-default")
        XCTAssertEqual(merged.reminderListIDs, ["local-extra"])
        XCTAssertEqual(store.customers.count, 3)
        let conflictCopy = try XCTUnwrap(store.customers.first(where: { $0.name == "Old name (Konfliktkopie)" }))
        XCTAssertEqual(conflictCopy.defaultReminderListID, "local-default")
        XCTAssertEqual(conflictCopy.reminderListIDs, ["local-extra"])
        XCTAssertEqual(store.calendarCustomerMappings, ["local-calendar": local.id])
        XCTAssertTrue(store.automaticallyAssignCustomers)
    }

    func testPageSyncCarriesDrawingAndPortableTasksButRestoresLocalReminderLinks() throws {
        let source = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let createdNote = try XCTUnwrap(source.createNote())
        let pageID = try XCTUnwrap(source.addPage(to: createdNote.id))
        let note = try XCTUnwrap(source.notes.first(where: { $0.id == createdNote.id }))
        let taskID = UUID()
        let sourceDueDate = TaskDueDate(year: 2026, month: 10, day: 25)
        let localDueDate = TaskDueDate(year: 2026, month: 11, day: 2)
        let sourceTask = RecognizedTask(
            id: taskID, bounds: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
            recognizedText: "Call customer", correctedText: "Call customer", confidence: 0.9,
            isChecked: true, reminderIdentifier: "source-reminder-id",
            reminderCalendarIdentifier: "source-calendar-id", reminderStatus: .completed,
            reminderLastSyncedIsChecked: true, dueDate: sourceDueDate,
            reminderDueDateSyncPending: true,
            isIgnored: true, reminderRemovalPending: true, reminderRestorePending: true
        )
        source.saveRecognizedTasks([sourceTask], for: pageID)
        let drawing = PKDrawing()
        source.saveDrawing(drawing, for: pageID)

        let record = try XCTUnwrap(source.cloudRecord(
            for: CKRecord.ID(recordName: "page-\(pageID.uuidString)", zoneID: zoneID), zoneID: zoneID
        ))
        let portableTasks = try JSONDecoder().decode([RecognizedTask].self, from: XCTUnwrap(record["tasks"] as? Data))
        let portableTask = try XCTUnwrap(portableTasks.first)
        XCTAssertEqual(portableTask.id, taskID)
        XCTAssertEqual(portableTask.title, "Call customer")
        XCTAssertNil(portableTask.reminderIdentifier)
        XCTAssertNil(portableTask.reminderCalendarIdentifier)
        XCTAssertNil(portableTask.reminderStatus)
        XCTAssertNil(portableTask.reminderLastSyncedIsChecked)
        XCTAssertEqual(portableTask.dueDate, sourceDueDate)
        XCTAssertFalse(portableTask.reminderDueDateSyncPending)
        XCTAssertTrue(portableTask.isIgnored)
        XCTAssertFalse(portableTask.reminderRemovalPending)
        XCTAssertFalse(portableTask.reminderRestorePending)

        let receiverURL = storageURL.appendingPathComponent("receiver", isDirectory: true)
        let receiver = NoteStore(storageDirectory: receiverURL, fileManager: fileManager)
        let noteRecord = CKRecord(
            recordType: "Note",
            recordID: CKRecord.ID(recordName: "note-\(note.id.uuidString)", zoneID: zoneID)
        )
        noteRecord["payload"] = try JSONEncoder().encode(note) as NSData
        try receiver.applyCloudRecord(noteRecord)
        receiver.saveRecognizedTasks([RecognizedTask(
            id: taskID, bounds: sourceTask.bounds, recognizedText: "Old local title", correctedText: nil,
            confidence: sourceTask.confidence, isChecked: false,
            reminderIdentifier: "receiver-reminder-id", reminderCalendarIdentifier: "receiver-calendar-id",
            reminderStatus: .open, reminderLastSyncedIsChecked: false,
            dueDate: localDueDate, reminderDueDateSyncPending: true
        )], for: pageID)
        try receiver.applyCloudRecord(record)

        let receivedTask = try XCTUnwrap(receiver.recognizedTasks(for: pageID).first)
        XCTAssertEqual(receivedTask.title, "Call customer")
        XCTAssertEqual(receivedTask.isChecked, true)
        XCTAssertEqual(receivedTask.reminderIdentifier, "receiver-reminder-id")
        XCTAssertEqual(receivedTask.reminderCalendarIdentifier, "receiver-calendar-id")
        XCTAssertEqual(receivedTask.reminderStatus, .open)
        XCTAssertEqual(receivedTask.reminderLastSyncedIsChecked, false)
        XCTAssertEqual(receivedTask.dueDate, localDueDate)
        XCTAssertTrue(receivedTask.reminderDueDateSyncPending)
        XCTAssertTrue(receiver.drawing(for: pageID).strokes.isEmpty)

        let freshReceiverURL = storageURL.appendingPathComponent("fresh-receiver", isDirectory: true)
        let freshReceiver = NoteStore(storageDirectory: freshReceiverURL, fileManager: fileManager)
        try freshReceiver.applyCloudRecord(noteRecord)
        try freshReceiver.applyCloudRecord(record)
        XCTAssertEqual(freshReceiver.recognizedTasks(for: pageID).first?.dueDate, sourceDueDate)
        XCTAssertEqual(freshReceiver.recognizedTasks(for: pageID).first?.isIgnored, true)
        XCTAssertEqual(freshReceiver.recognizedTasks(for: pageID).first?.reminderRemovalPending, false)
        XCTAssertEqual(freshReceiver.recognizedTasks(for: pageID).first?.reminderRestorePending, false)

        let linkedReceiverURL = storageURL.appendingPathComponent("linked-receiver", isDirectory: true)
        let linkedReceiver = NoteStore(storageDirectory: linkedReceiverURL, fileManager: fileManager)
        try linkedReceiver.applyCloudRecord(noteRecord)
        linkedReceiver.saveRecognizedTasks([RecognizedTask(
            id: taskID, bounds: sourceTask.bounds, recognizedText: "Old local title", correctedText: nil,
            confidence: sourceTask.confidence, isChecked: false,
            reminderIdentifier: "linked-reminder-id", reminderCalendarIdentifier: "linked-calendar-id",
            reminderStatus: .open, reminderLastSyncedIsChecked: false
        )], for: pageID)
        try linkedReceiver.applyCloudRecord(record)
        let linkedTask = try XCTUnwrap(linkedReceiver.recognizedTasks(for: pageID).first)
        XCTAssertEqual(linkedTask.dueDate, sourceDueDate)
        XCTAssertTrue(linkedTask.reminderDueDateSyncPending)
    }

    func testCloudDateMetadataTravelsTogetherAndPendingRemovalKeepsLocalOwnership() throws {
        let source = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(source.createNote())
        var task = RecognizedTask(
            id: UUID(), bounds: CGRect(x: 30, y: 40, width: 20, height: 20),
            recognizedText: "Kunden morgen anrufen", correctedText: nil,
            confidence: 0.95, isChecked: false
        )
        let anchor = TaskDueDate(year: 2026, month: 9, day: 28)
        task.dueDate = TaskDueDate(year: 2026, month: 9, day: 29)
        task.dueDateSource = .automatic
        task.dueDateReferenceDate = anchor
        task.dueDateReferenceIsTrusted = true
        task.dueDateLastAnalyzedText = task.recognizedText
        source.saveRecognizedTasks([task], for: note.id)
        let page = try XCTUnwrap(source.cloudRecord(
            for: CKRecord.ID(recordName: "page-\(note.id.uuidString)", zoneID: zoneID), zoneID: zoneID
        ))
        let metadata = try XCTUnwrap(source.cloudRecord(
            for: CKRecord.ID(recordName: "note-\(note.id.uuidString)", zoneID: zoneID), zoneID: zoneID
        ))
        let receiver = NoteStore(
            storageDirectory: storageURL.appendingPathComponent("date-receiver"), fileManager: fileManager
        )
        try receiver.applyCloudRecord(metadata)
        try receiver.applyCloudRecord(page)
        let imported = try XCTUnwrap(receiver.recognizedTasks(for: note.id).first)
        XCTAssertEqual(imported.dueDateSource, .automatic)
        XCTAssertEqual(imported.dueDateReferenceDate, anchor)
        XCTAssertTrue(imported.dueDateReferenceIsTrusted)
        XCTAssertEqual(imported.dueDateLastAnalyzedText, task.recognizedText)

        var removed = imported
        removed.reminderIdentifier = "local-reminder"
        removed.dueDate = nil
        removed.dueDateSource = .manual
        removed.reminderDueDateSyncPending = true
        receiver.saveRecognizedTasks([removed], for: note.id)
        try receiver.applyCloudRecord(page)
        let kept = try XCTUnwrap(receiver.recognizedTasks(for: note.id).first)
        XCTAssertNil(kept.dueDate)
        XCTAssertEqual(kept.dueDateSource, .manual)
        XCTAssertEqual(kept.dueDateReferenceDate, anchor)
        XCTAssertNil(kept.dueDateProposal)
        XCTAssertTrue(kept.reminderDueDateSyncPending)

        removed.reminderDueDateSyncPending = false
        receiver.saveRecognizedTasks([removed], for: note.id)
        try receiver.applyCloudRecord(page)
        let protected = try XCTUnwrap(receiver.recognizedTasks(for: note.id).first)
        XCTAssertNil(protected.dueDate)
        XCTAssertEqual(protected.dueDateSource, .manual)
        XCTAssertFalse(protected.reminderDueDateSyncPending)
    }

    func testMetadataBeforePageAssetLeavesDrawingWritableAfterImport() throws {
        let source = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(source.createNote())
        let receiverURL = storageURL.appendingPathComponent("receiver", isDirectory: true)
        let receiver = NoteStore(storageDirectory: receiverURL, fileManager: fileManager)
        let noteRecord = try XCTUnwrap(source.cloudRecord(
            for: CKRecord.ID(recordName: "note-\(note.id.uuidString)", zoneID: zoneID), zoneID: zoneID
        ))
        let pageRecord = try XCTUnwrap(source.cloudRecord(
            for: CKRecord.ID(recordName: "page-\(note.id.uuidString)", zoneID: zoneID), zoneID: zoneID
        ))

        try receiver.applyCloudRecord(noteRecord)
        XCTAssertNil(receiver.thumbnail(for: note.id))
        XCTAssertNil(receiver.errorMessage)
        let reopened = NoteStore(storageDirectory: receiverURL, fileManager: fileManager)
        reopened.saveDrawing(PKDrawing(), for: note.id)
        XCTAssertEqual(reopened.errorMessage, "Diese Zeichnung ist noch nicht verfügbar und blieb unverändert.")

        reopened.errorMessage = nil
        try reopened.applyCloudRecord(pageRecord)
        XCTAssertNotNil(reopened.thumbnail(for: note.id))
        XCTAssertNil(reopened.errorMessage)
        reopened.saveDrawing(PKDrawing(), for: note.id)
        XCTAssertNil(reopened.errorMessage)
    }

    func testPageEditDateSurvivesRestartAndIsIncludedInCloudRecord() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        store.saveDrawing(PKDrawing(), for: note.id)
        let recordID = CKRecord.ID(recordName: "page-\(note.id.uuidString)", zoneID: zoneID)
        let editedAt = try XCTUnwrap(store.cloudLocalEditDate(for: recordID))
        let record = try XCTUnwrap(store.cloudRecord(for: recordID, zoneID: zoneID))
        let exported = try XCTUnwrap(record["editedAt"] as? Date)
        XCTAssertEqual(exported, editedAt)

        let reopened = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let persisted = try XCTUnwrap(reopened.cloudLocalEditDate(for: recordID))
        XCTAssertEqual(persisted.timeIntervalSince1970, editedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "Notizen", ownerName: CKCurrentUserDefaultName)
    }

    private func makeEvent() -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: "event-occurrence-2026-09-24",
            eventIdentifier: "eventkit-event-id-on-this-device",
            calendarIdentifier: "eventkit-calendar-id-on-this-device",
            calendarTitle: "Work",
            title: "Planning meeting",
            startDate: Date(timeIntervalSinceReferenceDate: 100),
            endDate: Date(timeIntervalSinceReferenceDate: 200),
            isAllDay: false
        )
    }
}

private struct CloudPayload: Codable {
    let customers: [CloudCustomerPayload]
}

private struct CloudCustomerPayload: Codable {
    let id: UUID
    let name: String
    let isArchived: Bool
}

private enum SimulatedCloudKitDelegate {
    @TaskLocal static var isActive = false
}

@MainActor
private final class ScheduledUploadProbe {
    var executed = false
    var inheritedDelegateContext = false
    var ranOnMainActor = false
}

@MainActor
private final class CloudSyncCycleProbe {
    var runCount = 0
    var operationWasCancelled = false
    var inheritedDelegateContext = false
    var finished = false
    private var release: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { release = $0 }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}
