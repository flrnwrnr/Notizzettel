import SwiftUI

@main
struct NotizenApp: App {
    @StateObject private var store = NoteStore()
    @StateObject private var reminderService = ReminderService()
    @StateObject private var calendarService = CalendarService()
    @StateObject private var obsidianExport = ObsidianExportService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            GalleryView()
                .environmentObject(store)
                .environmentObject(reminderService)
                .environmentObject(calendarService)
                .environmentObject(obsidianExport)
                .preferredColorScheme(.light)
                .task { obsidianExport.bind(to: store) }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await store.syncNow() }
                        reminderService.refresh()
                        calendarService.refresh()
                        obsidianExport.retryPendingFailures()
                    }
                }
        }
    }
}
