import SwiftUI
import UIKit

struct CustomerReminderListsView: View {
    let customerID: UUID
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var reminderService: ReminderService
    @Environment(\.openURL) private var openURL

    private var customer: Customer? { store.customer(for: customerID) }
    private var unavailableIDs: [String] {
        let ids = Set((customer?.reminderListIDs ?? []) + [customer?.defaultReminderListID].compactMap { $0 })
        return ids.subtracting(Set(reminderService.lists.map(\.id))).sorted()
    }

    var body: some View {
        List {
            if reminderService.hasAccess {
                Section {
                    Picker("Standardliste", selection: Binding(
                        get: { customer?.defaultReminderListID ?? "" },
                        set: { update(defaultID: $0.isEmpty ? nil : $0) }
                    )) {
                        Text("Beim ersten Erkennen auswählen").tag("")
                        ForEach(reminderService.lists) { list in
                            Text("\(list.title) · \(list.sourceTitle)").tag(list.id)
                        }
                        if let id = customer?.defaultReminderListID,
                           !reminderService.lists.contains(where: { $0.id == id }) {
                            Text("Nicht mehr verfügbar").tag(id)
                        }
                    }
                } header: {
                    Text("Standard für neue Erinnerungen")
                } footer: {
                    Text("Gilt für Notizen dieses Kunden, bis du in einer Notiz eine andere Liste festlegst. Ein passenderer Vorschlag wird vor dem Erstellen zur Bestätigung angezeigt.")
                }

                Section {
                    ForEach(reminderService.lists) { list in
                        Toggle(isOn: Binding(
                            get: { customer?.defaultReminderListID == list.id || customer?.reminderListIDs.contains(list.id) == true },
                            set: { selected in
                                var ids = customer?.reminderListIDs ?? []
                                ids.removeAll { $0 == list.id }
                                if selected { ids.append(list.id) }
                                store.setCustomerReminderLists(customerID, defaultListID: customer?.defaultReminderListID, additionalListIDs: ids)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(list.title)
                                Text(customer?.defaultReminderListID == list.id ? "Standardliste · \(list.sourceTitle)" : list.sourceTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(customer?.defaultReminderListID == list.id)
                    }
                    if reminderService.lists.isEmpty {
                        Text("Keine beschreibbaren Erinnerungslisten verfügbar.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Zugehörige Listen")
                } footer: {
                    Text("Die App bevorzugt diese Listen bei Vorschlägen. Bestätigte Entscheidungen werden lokal gespeichert und verbessern künftige Vorschläge für diesen Kunden. Eine Liste darf mehreren Kunden gehören.")
                }

                if !unavailableIDs.isEmpty {
                    Section("Nicht verfügbare Listen") {
                        ForEach(unavailableIDs, id: \.self) { id in
                            HStack {
                                Text(customer?.defaultReminderListID == id ? "Standardliste nicht verfügbar" : "Zugehörige Liste nicht verfügbar")
                                Spacer()
                                Button("Entfernen", role: .destructive) {
                                    store.setCustomerReminderLists(
                                        customerID,
                                        defaultListID: customer?.defaultReminderListID == id ? nil : customer?.defaultReminderListID,
                                        additionalListIDs: (customer?.reminderListIDs ?? []).filter { $0 != id }
                                    )
                                }
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text("Erlaube den Zugriff auf Erinnerungen, um Listen für diesen Kunden auszuwählen.")
                    Button("Zugriff erlauben") {
                        Task { await reminderService.requestAccess() }
                    }
                    .disabled(reminderService.isRequestingAccess)
                    Button("Systemeinstellungen öffnen") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Erinnerungslisten")
        .navigationBarTitleDisplayMode(.inline)
        .task { reminderService.refresh() }
    }

    private func update(defaultID: String?) {
        store.setCustomerReminderLists(customerID, defaultListID: defaultID, additionalListIDs: customer?.reminderListIDs ?? [])
    }
}
