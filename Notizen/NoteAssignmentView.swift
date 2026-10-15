import SwiftUI

struct NoteAssignmentView: View {
    let noteID: UUID

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var calendarService: CalendarService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDate: Date?

    private var note: Note? {
        store.notes.first { $0.id == noteID }
    }

    private var activeCustomers: [Customer] {
        store.customers.filter { !$0.isArchived }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedCustomer: Customer? {
        store.customer(for: note?.customerID)
    }

    private var assignableEvents: [(event: CalendarEventSnapshot, customer: Customer)] {
        guard let note else { return [] }
        let date = selectedDate ?? note.createdAt
        return calendarService.events(on: date).compactMap { event in
            guard !event.title.localizedCaseInsensitiveContains("blocker"),
                  let customerID = store.calendarCustomerMappings[event.calendarIdentifier],
                  let customer = store.customer(for: customerID),
                  !customer.isArchived else { return nil }
            return (event, customer)
        }
        .sorted { $0.event.startDate < $1.event.startDate }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let note {
                    List {
                        currentAssignmentSection(note)
                        manualAssignmentSection(note)
                        eventAssignmentSection(note)

                        if let error = calendarService.errorMessage ?? store.errorMessage {
                            Section {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Notiz nicht gefunden", systemImage: "note.text")
                }
            }
            .navigationTitle("Kunde zuordnen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .task {
                if selectedDate == nil {
                    selectedDate = note?.createdAt
                }
                calendarService.refresh()
            }
        }
    }

    @ViewBuilder
    private func currentAssignmentSection(_ note: Note) -> some View {
        if note.customerID != nil || note.calendarEvent != nil {
            Section {
                if let customer = selectedCustomer {
                    HStack {
                        Text(customer.name)
                        if customer.isArchived {
                            Text("Archiviert")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if note.customerID != nil {
                    Text("Nicht mehr verfügbarer Kunde")
                        .foregroundStyle(.secondary)
                }

                if let event = note.calendarEvent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title)
                            .fontWeight(.medium)
                        Text(event.calendarTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(eventTimeDescription(event))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                Button("Zuordnung entfernen", role: .destructive) {
                    store.assignCustomer(nil, event: nil, to: note.id)
                }
            } header: {
                Text(note.calendarEvent == nil ? "Aktuelle Zuordnung" : "Gespeicherter Termin")
            } footer: {
                if note.calendarEvent != nil {
                    Text("Historischer Stand beim Zuordnen. Er bleibt sichtbar, auch wenn der Kalender oder Zugriff später nicht mehr verfügbar ist.")
                }
            }
        }
    }

    private func manualAssignmentSection(_ note: Note) -> some View {
        Section {
            if activeCustomers.isEmpty {
                Text("Keine aktiven Kunden vorhanden")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activeCustomers) { customer in
                    Button {
                        let existingEvent = note.customerID == customer.id ? note.calendarEvent : nil
                        store.assignCustomer(customer.id, event: existingEvent, to: note.id)
                    } label: {
                        HStack {
                            Text(customer.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if note.customerID == customer.id {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Kunde manuell")
        } footer: {
            Text("Beim Wechsel zu einem anderen Kunden wird ein zuvor gespeicherter Termin entfernt.")
        }
    }

    private func eventAssignmentSection(_ note: Note) -> some View {
        Section {
            DatePicker(
                "Datum",
                selection: Binding(
                    get: { selectedDate ?? note.createdAt },
                    set: { selectedDate = $0 }
                ),
                displayedComponents: .date
            )

            if !calendarService.hasAccess {
                Text("Kalenderzugriff ist in den Einstellungen erforderlich.")
                    .foregroundStyle(.secondary)
            } else if assignableEvents.isEmpty {
                Text("Keine zugeordneten Kundentermine an diesem Tag")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(assignableEvents, id: \.event.id) { item in
                    Button {
                        store.assignCustomer(item.customer.id, event: item.event, to: note.id)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.event.title)
                                    .foregroundStyle(.primary)
                                Text(eventTimeDescription(item.event))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.customer.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        } header: {
            Text("Kalendertermin")
        } footer: {
            Text("Wähle einen Kunden direkt oder über einen passenden Termin. Beim Öffnen wird keine Zuordnung verändert.")
        }
    }

    private func eventTimeDescription(_ event: CalendarEventSnapshot) -> String {
        if event.isAllDay {
            return event.startDate.formatted(date: .abbreviated, time: .omitted) + " · Ganztägig"
        }
        let date = event.startDate.formatted(date: .abbreviated, time: .omitted)
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(date) · \(start)–\(end)"
    }
}
