import SwiftUI
import UIKit

struct CustomerCalendarSelectionView: View {
    let customerID: UUID

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var calendarService: CalendarService
    @Environment(\.openURL) private var openURL
    @State private var pendingTransfer: PendingTransfer?

    private struct PendingTransfer {
        let calendar: CalendarSource
        let previousCustomerID: UUID
    }

    private var unavailableOwnIDs: [String] {
        let availableIDs = Set(calendarService.calendars.map(\.id))
        return store.calendarCustomerMappings
            .filter { $0.value == customerID && !availableIDs.contains($0.key) }
            .map(\.key)
            .sorted()
    }

    var body: some View {
        List {
            if calendarService.hasAccess {
                Section {
                    if calendarService.calendars.isEmpty {
                        Text("Keine Kalender verfügbar")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(calendarService.calendars) { calendar in
                        Toggle(isOn: binding(for: calendar)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(calendar.title)
                                Text(calendarSubtitle(calendar))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Kalender")
                } footer: {
                    Text("Ein Kunde kann mehrere Kalender haben. Ein bereits zugeordneter Kalender wird nur nach deiner Bestätigung übertragen.")
                }

                if !unavailableOwnIDs.isEmpty {
                    Section {
                        ForEach(unavailableOwnIDs, id: \.self) { calendarID in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Kalender nicht verfügbar")
                                    Text("Die gespeicherte Zuordnung besteht weiterhin.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Entfernen", role: .destructive) {
                                    guard store.calendarCustomerMappings[calendarID] == customerID else { return }
                                    store.setCalendarCustomer(calendarID, customerID: nil)
                                }
                            }
                        }
                    } header: {
                        Text("Nicht verfügbare Kalender")
                    } footer: {
                        Text("Entfernen ändert keine bereits gespeicherten Notizen.")
                    }
                }
            } else {
                Section {
                    Text("Erlaube den Kalenderzugriff, um Kalender für diesen Kunden auszuwählen.")
                    Button("Zugriff erlauben") {
                        Task { await calendarService.requestAccess() }
                    }
                    .disabled(calendarService.isRequestingAccess)
                    if calendarService.errorMessage != nil {
                        Button("Systemeinstellungen öffnen") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                    }
                }
            }

            if let error = calendarService.errorMessage ?? store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Kalender")
        .navigationBarTitleDisplayMode(.inline)
        .task { calendarService.refresh() }
        .alert("Kalender übertragen?", isPresented: Binding(
            get: { pendingTransfer != nil },
            set: { if !$0 { pendingTransfer = nil } }
        )) {
            Button("Übertragen") {
                guard let pendingTransfer,
                      calendarService.hasAccess,
                      store.calendarCustomerMappings[pendingTransfer.calendar.id] == pendingTransfer.previousCustomerID else { return }
                store.setCalendarCustomer(pendingTransfer.calendar.id, customerID: customerID)
                self.pendingTransfer = nil
            }
            Button("Abbrechen", role: .cancel) { pendingTransfer = nil }
        } message: {
            if let pendingTransfer {
                let previousName = store.customer(for: pendingTransfer.previousCustomerID)?.name ?? "einem anderen Kunden"
                Text("„\(pendingTransfer.calendar.title)“ ist bereits „\(previousName)“ zugeordnet. Soll der Kalender diesem Kunden zugeordnet werden?")
            }
        }
    }

    private func binding(for calendar: CalendarSource) -> Binding<Bool> {
        Binding(
            get: { store.calendarCustomerMappings[calendar.id] == customerID },
            set: { selected in
                guard calendarService.hasAccess else { return }
                let currentOwner = store.calendarCustomerMappings[calendar.id]
                if selected {
                    if let currentOwner, currentOwner != customerID {
                        pendingTransfer = PendingTransfer(calendar: calendar, previousCustomerID: currentOwner)
                    } else {
                        store.setCalendarCustomer(calendar.id, customerID: customerID)
                    }
                } else if currentOwner == customerID {
                    store.setCalendarCustomer(calendar.id, customerID: nil)
                }
            }
        )
    }

    private func calendarSubtitle(_ calendar: CalendarSource) -> String {
        let source = calendar.sourceTitle == calendar.title ? "" : "\(calendar.sourceTitle) · "
        guard let ownerID = store.calendarCustomerMappings[calendar.id] else {
            return "\(source)Nicht zugeordnet"
        }
        guard ownerID != customerID else { return "\(source)Diesem Kunden zugeordnet" }
        let owner = store.customer(for: ownerID)
        let ownerName = owner?.name ?? "Unbekannter Kunde"
        let archiveLabel = owner?.isArchived == true ? " (archiviert)" : ""
        return "\(source)Zugeordnet: \(ownerName)\(archiveLabel)"
    }
}
