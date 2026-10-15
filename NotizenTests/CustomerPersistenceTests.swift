import Foundation
import XCTest

@testable import Notizen

@MainActor
final class CustomerPersistenceTests: XCTestCase {
    private var storageURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        storageURL = fileManager.temporaryDirectory
            .appendingPathComponent("CustomerPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
    }

    func testLegacyNotesDecodeWithoutCustomerOrEvent() throws {
        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let id = UUID()
        let legacy = LegacyNote(id: id, createdAt: Date(), updatedAt: Date(), pageIDs: [id])
        try JSONEncoder().encode([legacy]).write(to: notesURL, options: .atomic)

        let note = try XCTUnwrap(NoteStore(storageDirectory: storageURL).notes.first)
        XCTAssertNil(note.customerID)
        XCTAssertNil(note.calendarEvent)
    }

    func testCustomersMappingsSettingsAndAssignedSnapshotReload() throws {
        let store = NoteStore(storageDirectory: storageURL)
        let customer = try XCTUnwrap(store.createCustomer(name: "  Acme  "))
        let event = makeEvent(calendarID: "work")
        store.setCalendarCustomer("work", customerID: customer.id)
        store.setAutomaticCustomerAssignment(true)
        let note = try XCTUnwrap(store.createNote(customerID: customer.id, event: event))

        let reloaded = NoteStore(storageDirectory: storageURL)
        XCTAssertEqual(reloaded.customers, [Customer(id: customer.id, name: "Acme", isArchived: false)])
        XCTAssertEqual(reloaded.calendarCustomerMappings, ["work": customer.id])
        XCTAssertTrue(reloaded.automaticallyAssignCustomers)
        XCTAssertEqual(reloaded.notes.first(where: { $0.id == note.id })?.customerID, customer.id)
        XCTAssertEqual(reloaded.notes.first(where: { $0.id == note.id })?.calendarEvent, event)
    }

    func testArchivingAndRemovingMappingPreserveExistingNoteAssignmentAndSnapshot() throws {
        let store = NoteStore(storageDirectory: storageURL)
        let customer = try XCTUnwrap(store.createCustomer(name: "Acme"))
        let event = makeEvent(calendarID: "work")
        store.setCalendarCustomer("work", customerID: customer.id)
        store.setAutomaticCustomerAssignment(true)
        let existing = try XCTUnwrap(store.createNote(customerID: customer.id, event: event))

        store.setCustomerArchived(customer.id, archived: true)
        store.setCalendarCustomer("work", customerID: nil)

        XCTAssertEqual(store.notes.first(where: { $0.id == existing.id })?.customerID, customer.id)
        XCTAssertEqual(store.notes.first(where: { $0.id == existing.id })?.calendarEvent, event)
        XCTAssertNil(store.createNote(event: event)?.customerID)
        XCTAssertNil(store.calendarCustomerMappings["work"])
    }

    func testCreateNotePersistsOnlyTheSuppliedCustomer() throws {
        let store = NoteStore(storageDirectory: storageURL)
        let customer = try XCTUnwrap(store.createCustomer(name: "Acme"))
        store.setCalendarCustomer("work", customerID: customer.id)
        store.setAutomaticCustomerAssignment(true)
        store.setCustomerArchived(customer.id, archived: true)

        XCTAssertNil(store.createNote(event: makeEvent(calendarID: "work"))?.customerID)
        XCTAssertEqual(
            store.createNote(customerID: customer.id, event: makeEvent(calendarID: "work"))?.customerID,
            customer.id
        )
    }

    func testInvalidCustomerIDsAreRejected() throws {
        let store = NoteStore(storageDirectory: storageURL)
        let note = try XCTUnwrap(store.createNote())
        let unknownID = UUID()

        XCTAssertNil(store.createNote(customerID: unknownID))
        store.setCalendarCustomer("work", customerID: unknownID)
        store.assignCustomer(unknownID, event: makeEvent(calendarID: "work"), to: note.id)

        XCTAssertTrue(store.calendarCustomerMappings.isEmpty)
        XCTAssertNil(store.notes.first(where: { $0.id == note.id })?.customerID)
        XCTAssertNil(store.notes.first(where: { $0.id == note.id })?.calendarEvent)
    }

    func testCorruptOrganizationFileIsNeverOverwritten() throws {
        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let corruptData = Data("not-json".utf8)
        try corruptData.write(to: organizationURL, options: .atomic)
        let store = NoteStore(storageDirectory: storageURL)

        XCTAssertNil(store.createCustomer(name: "Must not write"))
        store.setAutomaticCustomerAssignment(true)

        XCTAssertEqual(try Data(contentsOf: organizationURL), corruptData)
        XCTAssertFalse(store.automaticallyAssignCustomers)
    }

    private func makeEvent(calendarID: String) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: "event-1@2026-09-23T08:00:00Z",
            eventIdentifier: "event-1",
            calendarIdentifier: calendarID,
            calendarTitle: "Work",
            title: "Meeting",
            startDate: Date(timeIntervalSinceReferenceDate: 100),
            endDate: Date(timeIntervalSinceReferenceDate: 200),
            isAllDay: false
        )
    }

    private var notesURL: URL { storageURL.appendingPathComponent("notes.json") }
    private var organizationURL: URL { storageURL.appendingPathComponent("organization.json") }
}

private struct LegacyNote: Codable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let pageIDs: [UUID]
}
