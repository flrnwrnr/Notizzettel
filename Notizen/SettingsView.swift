import SwiftUI
import UIKit

struct SettingsView: View {
    @AppStorage("newPagesRuled") private var newPagesRuled = true
    @AppStorage("allowFingerDrawing") private var allowFingerDrawing = false
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var calendarService: CalendarService
    @EnvironmentObject private var reminders: ReminderService
    @EnvironmentObject private var obsidianExport: ObsidianExportService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Nutzung") {
                NavigationLink { NotePageSettingsView() } label: {
                    row("Notizen", symbol: "note.text", status: newPagesRuled ? "Liniert" : "Blanko")
                }
                Toggle("Mit Finger zeichnen", isOn: $allowFingerDrawing)
            }

            Section("Integrationen") {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("iCloud-Synchronisierung").foregroundStyle(.primary)
                            Text(store.syncStatus).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "icloud").frame(width: 24)
                    }
                    Spacer()
                    Button("Jetzt synchronisieren") {
                        Task { await store.syncNow() }
                    }
                    .font(.subheadline)
                    .labelStyle(.titleOnly)
                }
                NavigationLink { ReminderSettingsView() } label: {
                    row("Erinnerungen", symbol: "checklist", status: reminderStatus,
                        hasError: reminders.errorMessage != nil)
                }
                NavigationLink { CalendarSettingsView() } label: {
                    row("Kalender", symbol: "calendar", status: calendarStatus,
                        hasError: calendarService.errorMessage != nil)
                }
                NavigationLink { ExportSettingsView() } label: {
                    row("Obsidian", symbol: "square.and.arrow.up", status: exportStatus,
                        hasError: obsidianExport.errorMessage != nil)
                }
            }

            Section("Kunden") {
                NavigationLink {
                    CustomerSettingsView()
                } label: {
                    row("Kunden verwalten", symbol: "person.2", status: "Kalender und Erinnerungslisten zuordnen")
                }
            }
        }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
        }
        .task {
            reminders.refresh()
            calendarService.refresh()
        }
    }

    private var reminderStatus: String {
        if !reminders.hasAccess { return "Zugriff fehlt" }
        if reminders.errorMessage != nil { return "Prüfen" }
        return reminders.automaticallyCreateReminders ? "Automatisch" : "Manuell"
    }

    private var calendarStatus: String {
        guard calendarService.hasAccess else { return "Zugriff fehlt" }
        if calendarService.errorMessage != nil { return "Prüfen" }
        return store.automaticallyAssignCustomers ? "Automatische Zuordnung" : "Manuelle Zuordnung"
    }

    private var exportStatus: String {
        if obsidianExport.errorMessage != nil { return "Fehler" }
        if obsidianExport.isExporting { return "Export läuft" }
        return obsidianExport.selectedFolderName == nil ? "Nicht eingerichtet" : "Obsidian verbunden"
    }

    private func row(_ title: String, symbol: String, status: String, hasError: Bool = false) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(status).font(.subheadline)
                    .foregroundColor(hasError ? .red : .secondary)
            }
        } icon: {
            Image(systemName: symbol).frame(width: 24)
        }
        .padding(.vertical, 2)
    }
}

private struct NotePageSettingsView: View {
    @AppStorage("newPagesRuled") private var newPagesRuled = true

    var body: some View {
        List {
            Section {
                Toggle("Neue Notizblätter liniert", isOn: $newPagesRuled)
            } footer: {
                Text("Die Einstellung gilt für neu hinzugefügte Blätter. Linien werden Bestandteil der Notiz.")
            }
        }
        .navigationTitle("Notizen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReminderSettingsView: View {
    @EnvironmentObject private var reminders: ReminderService
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                if reminders.hasAccess {
                    NavigationLink {
                        ReminderListSettingsView()
                    } label: {
                        HStack {
                            Text("Allgemeine Standardliste")
                            Spacer()
                            Text(selectedListTitle).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } else {
                    accessControls
                }
                Toggle("Erinnerungen automatisch erstellen", isOn: Binding(
                    get: { reminders.automaticallyCreateReminders },
                    set: { reminders.setAutomaticCreation($0) }
                ))
            } footer: {
                Text("Die Liste hier ist eine Vorauswahl. Eine für die Notiz gewählte Liste hat Vorrang, danach die Standardliste des Kunden. Ohne eindeutige Zuordnung wählst du die Liste bei der Notiz aus.")
            }
            Section {
                if reminders.automaticallyCreateReminders {
                    Text("Nach einer Schreibpause werden sicher erkannte Aufgaben automatisch angelegt. Unsichere oder leere Aufgaben bleiben zur Prüfung offen.")
                } else {
                    Text("Standardmäßig erstellst du jede Erinnerung selbst bei der erkannten Aufgabe.")
                }
            }
            if let errorMessage = reminders.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Erneut laden") { reminders.refresh() }
                }
            }
        }
        .navigationTitle("Erinnerungen")
        .navigationBarTitleDisplayMode(.inline)
        .task { reminders.refresh() }
    }

    private var selectedListTitle: String {
        reminders.lists.first(where: { $0.id == reminders.selectedListID })?.title ?? "Auswählen"
    }

    private var accessControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Erlaube den Zugriff, damit Aufgaben als Apple Erinnerungen angelegt und ihr Erledigt-Status synchronisiert werden kann.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                Task { await reminders.requestAccess() }
            } label: {
                if reminders.isRequestingAccess {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Zugriff erlauben").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(reminders.isRequestingAccess)
            if reminders.errorMessage != nil {
                Button("Systemeinstellungen öffnen") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ExportSettingsView: View {
    @EnvironmentObject private var obsidianExport: ObsidianExportService
    @State private var showingObsidianFolderPicker = false

    var body: some View {
        List {
            Section {
                Button(obsidianExport.selectedFolderName == nil ? "Obsidian-Ordner auswählen" : "Obsidian-Ordner ändern") {
                    showingObsidianFolderPicker = true
                }
                if let folder = obsidianExport.selectedFolderName {
                    Label(folder, systemImage: "folder").foregroundStyle(.secondary)
                    Button("Alle Notizen erneut exportieren") { obsidianExport.retryFailed() }
                        .disabled(obsidianExport.isExporting)
                }
                if obsidianExport.isExporting {
                    Label("Notizen werden exportiert …", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
                if let message = obsidianExport.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Obsidian")
            } footer: {
                Text("Wähle einen Ordner in deinem Obsidian-Vault oder einen anderen über die Dateien-App zugänglichen Archivordner. Gespeicherte Notizen werden automatisch als PDF und Markdown in Kunden-, Jahres- und Kalenderwochenordner exportiert. Ohne Kundenzuordnung entfallen die Kundenordner. Ordner entstehen nur bei einem Export. Spätere Änderungen ersetzen die Dateien; bearbeite den Export daher nicht direkt in Obsidian.")
            }
        }
        .navigationTitle("Obsidian")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingObsidianFolderPicker) {
            ObsidianFolderPicker { url in
                obsidianExport.selectFolder(url)
                showingObsidianFolderPicker = false
            }
        }
    }
}

private struct ReminderListSettingsView: View {
    @EnvironmentObject private var reminders: ReminderService

    var body: some View {
        List {
            if reminders.lists.isEmpty {
                ContentUnavailableView(
                    "Keine beschreibbare Liste",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Lege in Apple Erinnerungen eine Liste an oder prüfe deinen Zugriff.")
                )
            } else {
                ForEach(reminders.lists, id: \.id) { list in
                    Button {
                        reminders.selectList(list.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.title)
                                    .foregroundStyle(.primary)
                                if list.sourceTitle != list.title {
                                    Text(list.sourceTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if list.id == reminders.selectedListID {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .accessibilityLabel("Ausgewählt")
                            }
                        }
                    }
                }

                if !reminders.selectedListID.isEmpty,
                   !reminders.lists.contains(where: { $0.id == reminders.selectedListID }) {
                    Label(
                        "Die bisher ausgewählte Liste ist nicht mehr verfügbar. Wähle eine andere Liste.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Erinnerungsliste")
        .navigationBarTitleDisplayMode(.inline)
        .task { reminders.refresh() }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(NoteStore())
            .environmentObject(CalendarService())
            .environmentObject(ReminderService())
            .environmentObject(ObsidianExportService())
    }
}
