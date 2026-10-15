import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class ObsidianExportService: ObservableObject {
    @Published private(set) var selectedFolderName: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isExporting = false

    private struct ExportLocation: Codable {
        var folder: String
        var baseName: String
        var updatedAt: Date?
    }

    private let bookmarkKey = "obsidianExportFolderBookmark"
    private let locationsKey = "obsidianExportLocations"
    private var folderURL: URL?
    private var locations: [UUID: ExportLocation] = [:]
    private weak var store: NoteStore?
    private var subscriptions = Set<AnyCancellable>()
    private var pending = Set<UUID>()
    private var failed = Set<UUID>()
    private var observedDates: [UUID: Date] = [:]
    private var observedCustomerNames: [UUID: String] = [:]
    private var hasObservedNotes = false
    private var hasObservedCustomers = false
    private var worker: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: locationsKey),
           let saved = try? JSONDecoder().decode([UUID: ExportLocation].self, from: data) {
            locations = saved
        }
        restoreFolder()
    }

    func bind(to store: NoteStore) {
        guard self.store !== store else { return }
        self.store = store
        store.$notes.sink { [weak self] notes in
            guard let self else { return }
            let current = Dictionary(notes.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { _, latest in latest })
            let hadFailedExports = !self.failed.isEmpty
            self.failed.formIntersection(Set(current.keys))
            if hadFailedExports && self.failed.isEmpty { self.errorMessage = nil }
            for note in notes {
                let customerName = store.customer(for: note.customerID)?.name
                let expectedFolder = Self.relativeFolder(for: note.createdAt, customerName: customerName)
                if self.locations[note.id]?.folder != expectedFolder ||
                    (self.observedDates[note.id] != note.updatedAt &&
                     (self.hasObservedNotes || self.locations[note.id]?.updatedAt != note.updatedAt)) {
                    self.pending.insert(note.id)
                }
            }
            self.observedDates = current
            self.hasObservedNotes = true
            self.schedule()
        }.store(in: &subscriptions)

        store.$customers.sink { [weak self] customers in
            guard let self else { return }
            let names = Dictionary(customers.map { ($0.id, $0.name) }, uniquingKeysWith: { _, latest in latest })
            let changed = Set(names.keys.filter { self.observedCustomerNames[$0] != names[$0] })
            self.observedCustomerNames = names
            for note in store.notes {
                let expectedFolder = Self.relativeFolder(for: note.createdAt, customerName: note.customerID.flatMap { names[$0] })
                if (self.hasObservedCustomers && note.customerID.map(changed.contains) == true) ||
                    self.locations[note.id]?.folder != expectedFolder {
                    self.pending.insert(note.id)
                }
            }
            self.hasObservedCustomers = true
            self.schedule()
        }.store(in: &subscriptions)
    }

    func selectFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Der Obsidian-Ordner ist nicht erreichbar. Bitte wähle ihn erneut aus."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            // Locations are relative to the previously selected root and must not
            // be used to remove files from a newly selected vault.
            locations.removeAll()
            UserDefaults.standard.removeObject(forKey: locationsKey)
            folderURL = url
            selectedFolderName = url.lastPathComponent
            errorMessage = nil
            retryAll()
        } catch {
            errorMessage = "Der Obsidian-Ordner konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    func retryAll() {
        guard let store else { return }
        pending.formUnion(store.notes.map(\.id))
        errorMessage = nil
        schedule()
    }

    func retryPendingFailures() {
        pending.formUnion(failed)
        schedule()
    }

    func retryFailed() {
        guard folderURL != nil else {
            errorMessage = "Bitte wähle zuerst den Exportordner aus."
            return
        }
        retryAll()
    }

    private func restoreFolder() {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                guard url.startAccessingSecurityScopedResource() else {
                    throw CocoaError(.fileReadNoPermission)
                }
                defer { url.stopAccessingSecurityScopedResource() }
                UserDefaults.standard.set(
                    try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
                    forKey: bookmarkKey
                )
            }
            folderURL = url
            selectedFolderName = url.lastPathComponent
        } catch {
            errorMessage = "Der Obsidian-Ordner ist nicht mehr erreichbar. Bitte wähle ihn erneut aus."
        }
    }

    private func schedule() {
        guard folderURL != nil, worker == nil, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self else { return }
            await self.drain()
        }
    }

    private func drain() async {
        isExporting = true
        defer {
            isExporting = false
            worker = nil
            if !pending.isEmpty { schedule() }
        }
        while let noteID = pending.first {
            pending.remove(noteID)
            guard let note = store?.notes.first(where: { $0.id == noteID }) else { continue }
            do {
                try await export(note)
                failed.remove(noteID)
                if failed.isEmpty { errorMessage = nil }
            } catch {
                failed.insert(noteID)
                errorMessage = "Obsidian-Export fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    private func export(_ note: Note) async throws {
        guard let root = folderURL, let store else { return }
        guard root.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { root.stopAccessingSecurityScopedResource() }

        let customerName = store.customer(for: note.customerID)?.name
        var pages: [UIImage] = []
        for pageID in note.pageIDs {
            guard let image = store.renderedPage(for: pageID) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            pages.append(image)
        }
        let output = try await ObsidianExportContent.make(note: note, customerName: customerName, pages: pages)
        let folder = Self.relativeFolder(for: note.createdAt, customerName: customerName)
        let destination = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let location = ExportLocation(folder: folder, baseName: output.baseName, updatedAt: note.updatedAt)
        let pdf = destination.appendingPathComponent("\(output.baseName).pdf")
        let markdown = destination.appendingPathComponent("\(output.baseName).md")
        try coordinatedWrite(output.pdfData, to: pdf)
        try coordinatedWrite(Data(output.markdown.utf8), to: markdown)

        // Relocation removes the previous pair only after the new pair is complete.
        if let old = locations[note.id], old.folder != location.folder || old.baseName != location.baseName {
            let oldFolder = old.folder.isEmpty ? root : root.appendingPathComponent(old.folder, isDirectory: true)
            try coordinatedRemove(oldFolder.appendingPathComponent("\(old.baseName).pdf"))
            try coordinatedRemove(oldFolder.appendingPathComponent("\(old.baseName).md"))
        }
        locations[note.id] = location
        UserDefaults.standard.set(try JSONEncoder().encode(locations), forKey: locationsKey)
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        let options: NSFileCoordinator.WritingOptions = FileManager.default.fileExists(atPath: url.path) ? .forReplacing : []
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) }
            catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func coordinatedRemove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var removeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do { try FileManager.default.removeItem(at: target) }
            catch { removeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let removeError { throw removeError }
    }

    private static func safeFolderName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Kunde" : cleaned
    }

    static func relativeFolder(for createdAt: Date, customerName: String?) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let year = calendar.component(.yearForWeekOfYear, from: createdAt)
        let week = calendar.component(.weekOfYear, from: createdAt)
        let weekFolder = "\(year)/KW \(String(format: "%02d", week))"
        return customerName.map { "\(safeFolderName($0))/\(weekFolder)" } ?? weekFolder
    }
}

struct ObsidianFolderPicker: UIViewControllerRepresentable {
    let onSelect: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelect: (URL) -> Void
        init(onSelect: @escaping (URL) -> Void) { self.onSelect = onSelect }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onSelect(url) }
        }
    }
}
