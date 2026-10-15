import SwiftUI

struct CustomerDetailView: View {
    let customerID: UUID

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var calendarService: CalendarService
    @EnvironmentObject private var reminderService: ReminderService
    @State private var editedName = ""

    private var customer: Customer? { store.customer(for: customerID) }

    private var calendarCount: Int {
        store.calendarCustomerMappings.values.filter { $0 == customerID }.count
    }

    private var defaultReminderTitle: String {
        guard let id = customer?.defaultReminderListID else { return "Keine Standardliste" }
        guard reminderService.hasAccess else { return "Standardliste ausgewählt (Zugriff fehlt)" }
        return reminderService.lists.first(where: { $0.id == id })?.title ?? "Standardliste nicht verfügbar"
    }

    private var additionalReminderCount: Int {
        customer?.reminderListIDs.count ?? 0
    }

    var body: some View {
        List {
            if let customer {
                Section("Name") {
                    TextField("Kundenname", text: $editedName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                    Button("Name speichern", action: saveName)
                        .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editedName.trimmingCharacters(in: .whitespacesAndNewlines) == customer.name)
                }

                Section("Zuordnungen") {
                    NavigationLink {
                        CustomerCalendarSelectionView(customerID: customerID)
                    } label: {
                        detailRow("Kalender", symbol: "calendar", summary: "\(calendarCount) zugeordnet")
                    }
                    NavigationLink {
                        CustomerReminderListsView(customerID: customerID)
                    } label: {
                        detailRow("Erinnerungslisten", symbol: "checklist", summary: "\(defaultReminderTitle) · \(additionalReminderCount) weitere")
                    }
                }

                Section {
                    Button(customer.isArchived ? "Kunden reaktivieren" : "Kunden archivieren", systemImage: customer.isArchived ? "arrow.uturn.backward" : "archivebox") {
                        store.setCustomerArchived(customerID, archived: !customer.isArchived)
                    }
                    .foregroundStyle(customer.isArchived ? Color.primary : Color.red)
                } footer: {
                    Text("Beim Archivieren bleiben Notizen, Kalender und Erinnerungslisten diesem Kunden zugeordnet.")
                }
            } else {
                ContentUnavailableView("Kunde nicht verfügbar", systemImage: "person.crop.circle.badge.questionmark")
            }

            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(customer?.name ?? "Kunde")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            editedName = customer?.name ?? ""
            calendarService.refresh()
            reminderService.refresh()
        }
    }

    private func detailRow(_ title: String, symbol: String, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveName() {
        guard let customer else { return }
        let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != customer.name else { return }
        store.renameCustomer(customerID, name: name)
    }
}
