import Foundation
import XCTest

@testable import Notizen

@MainActor
final class ReminderRoutingTests: XCTestCase {
    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("ReminderRoutingTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func testLegacyCustomerAndOrganizationDecodeWithoutRoutingFields() throws {
        let customerID = UUID()
        let oldCustomer = """
        {"id":"\(customerID.uuidString)","name":"Müller","isArchived":false}
        """
        let customer = try JSONDecoder().decode(Customer.self, from: Data(oldCustomer.utf8))
        XCTAssertNil(customer.defaultReminderListID)
        XCTAssertEqual(customer.reminderListIDs, [])

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldOrganization = """
        {"customers":[\(oldCustomer)],"calendarCustomerMappings":{},"automaticallyAssignCustomers":false}
        """
        try Data(oldOrganization.utf8).write(
            to: directory.appendingPathComponent("organization.json"), options: .atomic
        )
        let store = NoteStore(storageDirectory: directory)
        XCTAssertEqual(store.customers, [customer])
        XCTAssertTrue(store.reminderRoutingExamples.isEmpty)
        store.setCustomerReminderLists(customerID, defaultListID: "general", additionalListIDs: ["project"])
        let reloaded = NoteStore(storageDirectory: directory)
        XCTAssertEqual(reloaded.customers.first?.defaultReminderListID, "general")
        XCTAssertEqual(reloaded.customers.first?.reminderListIDs, ["project"])
    }

    func testConfirmationPersistsAndCorrectionReplacesTrainingExample() throws {
        let store = NoteStore(storageDirectory: directory)
        let customer = try XCTUnwrap(store.createCustomer(name: "Müller"))
        store.setCustomerReminderLists(customer.id, defaultListID: "general", additionalListIDs: ["project"])
        let note = try XCTUnwrap(store.createNote(customerID: customer.id))
        XCTAssertTrue(store.confirmReminderList("project", for: note.id, context: "Umbau Dach"))
        XCTAssertTrue(store.confirmReminderList("general", for: note.id, context: "Büro"))

        let reloaded = NoteStore(storageDirectory: directory)
        XCTAssertEqual(reloaded.notes.first?.reminderListID, "general")
        XCTAssertEqual(reloaded.reminderRoutingExamples.count, 1)
        XCTAssertEqual(reloaded.reminderRoutingExamples.first?.listID, "general")
        XCTAssertEqual(reloaded.reminderRoutingExamples.first?.context, "Büro")
    }

    func testFixedUnavailableAndCustomerDefaultUnavailableNeverFallBack() throws {
        let store = NoteStore(storageDirectory: directory)
        let customer = try XCTUnwrap(store.createCustomer(name: "Müller"))
        store.setCustomerReminderLists(customer.id, defaultListID: "removed", additionalListIDs: ["project"])
        let note = try XCTUnwrap(store.createNote(customerID: customer.id))
        let missingDefault = store.reminderRoutingDecision(
            for: note.id, taskTitles: ["Umbau"], lists: lists, globalListID: "global"
        )
        XCTAssertNil(missingDefault.targetListID)
        XCTAssertEqual(missingDefault.suggestedListID, "removed")

        XCTAssertTrue(store.confirmReminderList("project", for: note.id, context: "Umbau"))
        let fixed = store.reminderRoutingDecision(
            for: note.id, taskTitles: [], lists: lists, globalListID: "global"
        )
        XCTAssertEqual(fixed.targetListID, "project")

        let unavailable = store.reminderRoutingDecision(
            for: note.id, taskTitles: [], lists: [lists[0]], globalListID: "global"
        )
        XCTAssertNil(unavailable.targetListID)
        XCTAssertEqual(unavailable.suggestedListID, "project")
    }

    func testDistinctConfirmationsTeachWithinCustomerButStillAskForAlternate() throws {
        let store = NoteStore(storageDirectory: directory)
        let firstCustomer = try XCTUnwrap(store.createCustomer(name: "Müller"))
        let otherCustomer = try XCTUnwrap(store.createCustomer(name: "Schmidt"))
        store.setCustomerReminderLists(firstCustomer.id, defaultListID: "global", additionalListIDs: ["project"])
        store.setCustomerReminderLists(otherCustomer.id, defaultListID: "global", additionalListIDs: ["project"])

        let first = try XCTUnwrap(store.createNote(customerID: firstCustomer.id))
        let second = try XCTUnwrap(store.createNote(customerID: firstCustomer.id))
        let target = try XCTUnwrap(store.createNote(customerID: firstCustomer.id))
        let unrelated = try XCTUnwrap(store.createNote(customerID: otherCustomer.id))
        XCTAssertTrue(store.confirmReminderList("project", for: first.id, context: "Altbau Fenster"))

        let once = store.reminderRoutingDecision(
            for: target.id, taskTitles: ["Altbau prüfen"], lists: lists, globalListID: "global"
        )
        XCTAssertEqual(once.targetListID, "global")

        XCTAssertTrue(store.confirmReminderList("project", for: second.id, context: "Altbau Fassade"))
        let learned = store.reminderRoutingDecision(
            for: target.id, taskTitles: ["Altbau prüfen"], lists: lists, globalListID: "global"
        )
        XCTAssertNil(learned.targetListID)
        XCTAssertEqual(learned.suggestedListID, "project")
        XCTAssertTrue(learned.requiresConfirmation)
        XCTAssertTrue(learned.reason?.contains("Bisherige") == true)

        let isolated = store.reminderRoutingDecision(
            for: unrelated.id, taskTitles: ["Altbau prüfen"], lists: lists, globalListID: "global"
        )
        XCTAssertEqual(isolated.targetListID, "global")
    }

    func testDistinctiveListTitleSuggestsAlternateOnFirstNoteAndDefaultCanBePromoted() throws {
        let store = NoteStore(storageDirectory: directory)
        let customer = try XCTUnwrap(store.createCustomer(name: "Müller"))
        store.setCustomerReminderLists(customer.id, defaultListID: "global", additionalListIDs: ["project"])
        let note = try XCTUnwrap(store.createNote(customerID: customer.id))
        let decision = store.reminderRoutingDecision(
            for: note.id, taskTitles: ["Umbau Fenster"], lists: lists, globalListID: "global"
        )
        XCTAssertNil(decision.targetListID)
        XCTAssertEqual(decision.suggestedListID, "project")
        XCTAssertTrue(store.confirmReminderList("project", for: note.id, context: "Umbau Fenster", setCustomerDefault: true))
        XCTAssertEqual(store.customer(for: customer.id)?.defaultReminderListID, "project")
        XCTAssertTrue(store.customer(for: customer.id)?.reminderListIDs.contains("global") == true)
    }

    func testTaskContextStillSuggestsProjectWithGenericAppointmentTitle() throws {
        let customer = Customer(id: UUID(), name: "Müller", isArchived: false, defaultReminderListID: "global", reminderListIDs: ["project"])
        let note = Note(id: UUID(), createdAt: Date(), updatedAt: Date(), customerID: customer.id,
                        calendarEvent: CalendarEventSnapshot(id: "event", eventIdentifier: nil, calendarIdentifier: "calendar", calendarTitle: "Müller", title: "Besprechung", startDate: Date(), endDate: Date(), isAllDay: false))
        let decision = ReminderRouting.decide(note: note, customer: customer, examples: [], taskTitles: ["Umbau prüfen"], lists: lists, globalListID: "global")
        XCTAssertEqual(decision.suggestedListID, "project")
        XCTAssertTrue(decision.requiresConfirmation)
    }

    func testRemovedCustomerMembershipExcludesPreviouslyLearnedList() throws {
        let store = NoteStore(storageDirectory: directory)
        let customer = try XCTUnwrap(store.createCustomer(name: "Müller"))
        store.setCustomerReminderLists(customer.id, defaultListID: "global", additionalListIDs: ["project"])
        for _ in 0..<2 {
            let note = try XCTUnwrap(store.createNote(customerID: customer.id))
            XCTAssertTrue(store.confirmReminderList("project", for: note.id, context: "Altbau"))
        }
        store.setCustomerReminderLists(customer.id, defaultListID: "global", additionalListIDs: [])
        let note = try XCTUnwrap(store.createNote(customerID: customer.id))
        let decision = store.reminderRoutingDecision(for: note.id, taskTitles: ["Altbau"], lists: lists, globalListID: "global")
        XCTAssertEqual(decision.targetListID, "global")
        XCTAssertFalse(decision.requiresConfirmation)
    }

    private var lists: [ReminderList] {
        [
            ReminderList(id: "global", title: "Allgemein", sourceTitle: "iCloud"),
            ReminderList(id: "project", title: "Müller – Umbau", sourceTitle: "iCloud")
        ]
    }
}
