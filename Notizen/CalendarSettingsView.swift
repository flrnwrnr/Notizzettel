import SwiftUI
import UIKit

struct CalendarSettingsView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var calendarService: CalendarService
    @Environment(\.openURL) private var openURL

    private var assignedCalendarCount: Int {
        let availableIDs = Set(calendarService.calendars.map(\.id))
        return store.calendarCustomerMappings.keys.filter { availableIDs.contains($0) }.count
    }

    var body: some View {
        List {
            Section {
                if calendarService.hasAccess {
                    Label("Kalenderzugriff erlaubt", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("\(assignedCalendarCount) von \(calendarService.calendars.count) Kalendern einem Kunden zugeordnet")
                        .foregroundStyle(.secondary)
                } else {
                    calendarAccessControls
                }
            } footer: {
                Text("Kalender verwaltest du unter Einstellungen > Kunden verwalten beim jeweiligen Kunden.")
            }

            Section {
                Toggle(
                    "Automatisch zuordnen",
                    isOn: Binding(
                        get: { store.automaticallyAssignCustomers },
                        set: { store.setAutomaticCustomerAssignment($0) }
                    )
                )
            } footer: {
                Text("Neue Notizen werden laufenden Kundenterminen zugeordnet. Läuft kein passender Termin, werden die nächsten 15 Minuten berücksichtigt. Ganztagstermine und „Blocker“ werden ignoriert. Bestehende Notizen bleiben unverändert.")
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
    }

    private var calendarAccessControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Erlaube den Kalenderzugriff, um Termine Kunden zuzuordnen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await calendarService.requestAccess() }
            } label: {
                if calendarService.isRequestingAccess {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Zugriff erlauben").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(calendarService.isRequestingAccess)

            if calendarService.errorMessage != nil {
                Button("Systemeinstellungen öffnen") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
