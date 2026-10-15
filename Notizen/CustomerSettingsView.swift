import SwiftUI

struct CustomerSettingsView: View {
    @EnvironmentObject private var store: NoteStore
    @State private var customerName = ""

    private var activeCustomers: [Customer] {
        store.customers.filter { !$0.isArchived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var archivedCustomers: [Customer] {
        store.customers.filter(\.isArchived)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section("Kunden") {
                if activeCustomers.isEmpty {
                    Text("Noch keine aktiven Kunden")
                        .foregroundStyle(.secondary)
                }

                ForEach(activeCustomers) { customer in
                    NavigationLink(customer.name) {
                        CustomerDetailView(customerID: customer.id)
                    }
                }

                HStack {
                    TextField("Neuer Kunde", text: $customerName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(createCustomer)
                    Button("Anlegen", action: createCustomer)
                        .disabled(customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !archivedCustomers.isEmpty {
                Section {
                    ForEach(archivedCustomers) { customer in
                        NavigationLink {
                            CustomerDetailView(customerID: customer.id)
                        } label: {
                            Label(customer.name, systemImage: "archivebox")
                        }
                    }
                } header: {
                    Text("Archiviert")
                } footer: {
                    Text("Archivieren erhält bestehende Notiz- und Kalenderzuordnungen. Archivierte Kunden werden für neue automatische Zuordnungen nicht berücksichtigt.")
                }
            }

            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Kunden")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func createCustomer() {
        let name = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, store.createCustomer(name: name) != nil else { return }
        customerName = ""
    }
}
