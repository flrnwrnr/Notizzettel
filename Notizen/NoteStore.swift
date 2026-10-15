import Combine
import CloudKit
import Foundation
import PencilKit
import UIKit

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var pageIDs: [UUID]
    var pageBackgrounds: [UUID: NotePageBackground]
    var customerID: UUID?
    var calendarEvent: CalendarEventSnapshot?
    var reminderListID: String?

    init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        pageIDs: [UUID]? = nil,
        pageBackgrounds: [UUID: NotePageBackground] = [:],
        customerID: UUID? = nil,
        calendarEvent: CalendarEventSnapshot? = nil,
        reminderListID: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pageIDs = Self.normalizedPageIDs(pageIDs, noteID: id)
        self.pageBackgrounds = pageBackgrounds
        self.customerID = customerID
        self.calendarEvent = calendarEvent
        self.reminderListID = reminderListID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case pageIDs
        case pageBackgrounds
        case customerID
        case calendarEvent
        case reminderListID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let decodedPageIDs = try container.decodeIfPresent([UUID].self, forKey: .pageIDs)
        pageIDs = Self.normalizedPageIDs(decodedPageIDs, noteID: id)
        pageBackgrounds = try container.decodeIfPresent([UUID: NotePageBackground].self, forKey: .pageBackgrounds) ?? [:]
        customerID = try container.decodeIfPresent(UUID.self, forKey: .customerID)
        calendarEvent = try container.decodeIfPresent(CalendarEventSnapshot.self, forKey: .calendarEvent)
        reminderListID = try container.decodeIfPresent(String.self, forKey: .reminderListID)
    }

    private static func normalizedPageIDs(_ pageIDs: [UUID]?, noteID: UUID) -> [UUID] {
        guard let pageIDs, !pageIDs.isEmpty else { return [noteID] }
        var seen = Set<UUID>()
        return pageIDs.filter { seen.insert($0).inserted }
    }
}

@MainActor
final class NoteStore: ObservableObject {
    static let pageSize = NotePagePresentation.pageSize

    @Published private(set) var notes: [Note] = []
    @Published private(set) var customers: [Customer] = []
    @Published private(set) var calendarCustomerMappings: [String: UUID] = [:]
    @Published private(set) var automaticallyAssignCustomers = false
    @Published private(set) var reminderRoutingExamples: [ReminderRoutingExample] = []
    @Published var errorMessage: String?
    @Published private(set) var searchIndexProgress = NoteSearchIndexProgress()
    @Published private(set) var searchIndexErrorMessage: String?
    @Published private(set) var syncStatus = "iCloud wird vorbereitet …"
    @Published private(set) var cloudPageRevisions: [UUID: Int] = [:]
    private var cloudSync: CloudSyncCoordinator?
    private var applyingCloudChange = false

    private let fileManager: FileManager
    private let storageURL: URL?
    private var storageIsUsable = true
    private var organizationStorageIsUsable = true
    private var unreadableDrawings = Set<UUID>()
    private var waitingForCloudPages = Set<UUID>()
    private var unreadableTaskFiles = Set<UUID>()
    private var upgradedLegacyThumbnails = Set<UUID>()
    private var cloudPageEditedAt: [UUID: Date] = [:]
    private let searchRecognizer: @Sendable (Data) async throws -> String
    private var searchPages: [UUID: NoteSearchIndex.Entry] = [:]
    private var searchTaskTitles: [UUID: [String]] = [:]
    private var searchPendingPages: [UUID] = []
    private var searchDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var searchWorker: Task<Void, Never>?
    private var searchGenerations: [UUID: Int] = [:]
    private var searchCheckedPages = Set<UUID>()
    private var searchFailedPages = Set<UUID>()

    private var newPageBackground: NotePageBackground {
        let key = NotePagePresentation.ruledNewPagesPreferenceKey
        return (UserDefaults.standard.object(forKey: key) as? Bool ?? true) ? .ruled : .plain
    }

    init(
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default,
        searchRecognizer: @escaping @Sendable (Data) async throws -> String = { data in
            try await NoteSearchIndex.recognize(data)
        }
    ) {
        self.fileManager = fileManager
        self.searchRecognizer = searchRecognizer

        do {
            let directory: URL
            if let storageDirectory {
                directory = storageDirectory
            } else {
                let applicationSupport = try fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                directory = applicationSupport.appendingPathComponent("Notizen", isDirectory: true)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: directory.appendingPathComponent("Drawings", isDirectory: true), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: directory.appendingPathComponent("Thumbnails", isDirectory: true), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: directory.appendingPathComponent("RecognizedTasks", isDirectory: true), withIntermediateDirectories: true)
            storageURL = directory
        } catch {
            storageURL = nil
            storageIsUsable = false
            errorMessage = "Notizen konnten nicht geöffnet werden: \(error.localizedDescription)"
            return
        }

        loadNotes()
        loadWaitingForCloudPages()
        loadCloudPageEditDates()
        loadOrganization()
        loadSearchIndex()
        startSearchIndexing()
        if storageDirectory == nil {
            Task { @MainActor [weak self] in self?.startCloudSync() }
        } else {
            syncStatus = "iCloud-Sync ist für diesen Speicher deaktiviert"
        }
    }

    func createNote(customerID: UUID? = nil, event: CalendarEventSnapshot? = nil) -> Note? {
        guard canWrite else { return nil }

        guard customerID == nil || customer(for: customerID) != nil else { return nil }

        let now = Date()
        let note = Note(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            pageBackgrounds: [:],
            customerID: customerID,
            calendarEvent: event
        )

        var styledNote = note
        styledNote.pageBackgrounds[note.id] = newPageBackground

        do {
            try writeDrawing(PKDrawing(), for: note.id)
            try writeThumbnail(for: PKDrawing(), noteID: note.id)
            var updatedNotes = notes
            updatedNotes.append(styledNote)
            try writeMetadata(updatedNotes)
            notes = sort(updatedNotes)
            queueSearchIndexing(for: note.id, delay: 0)
            return styledNote
        } catch {
            present(error, action: "Erstellen der Notiz")
            return nil
        }
    }

    @discardableResult
    func createCustomer(name: String) -> Customer? {
        guard canWriteOrganization else { return nil }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }
        let customer = Customer(id: UUID(), name: normalizedName, isArchived: false)
        var updatedCustomers = customers
        updatedCustomers.append(customer)
        guard persistOrganization(customers: updatedCustomers) else { return nil }
        customers = updatedCustomers
        return customer
    }

    func renameCustomer(_ id: UUID, name: String) {
        guard canWriteOrganization,
              let index = customers.firstIndex(where: { $0.id == id }) else { return }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        var updatedCustomers = customers
        updatedCustomers[index].name = normalizedName
        guard persistOrganization(customers: updatedCustomers) else { return }
        customers = updatedCustomers
    }

    func setCustomerArchived(_ id: UUID, archived: Bool) {
        guard canWriteOrganization,
              let index = customers.firstIndex(where: { $0.id == id }) else { return }
        var updatedCustomers = customers
        updatedCustomers[index].isArchived = archived
        guard persistOrganization(customers: updatedCustomers) else { return }
        customers = updatedCustomers
    }

    func setCalendarCustomer(_ calendarID: String, customerID: UUID?) {
        guard canWriteOrganization,
              customerID == nil || customer(for: customerID) != nil else { return }
        var updatedMappings = calendarCustomerMappings
        updatedMappings[calendarID] = customerID
        guard persistOrganization(calendarCustomerMappings: updatedMappings) else { return }
        calendarCustomerMappings = updatedMappings
    }

    func setAutomaticCustomerAssignment(_ enabled: Bool) {
        guard canWriteOrganization,
              persistOrganization(automaticallyAssignCustomers: enabled) else { return }
        automaticallyAssignCustomers = enabled
    }

    func setCustomerReminderLists(
        _ customerID: UUID,
        defaultListID: String?,
        additionalListIDs: [String]
    ) {
        guard canWriteOrganization,
              let index = customers.firstIndex(where: { $0.id == customerID }) else { return }
        let normalizedDefault = defaultListID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedDefault = normalizedDefault?.isEmpty == false ? normalizedDefault : nil
        var seen = Set<String>()
        let additional = additionalListIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != selectedDefault && seen.insert($0).inserted }
        var updated = customers
        updated[index].defaultReminderListID = selectedDefault
        updated[index].reminderListIDs = additional
        guard persistOrganization(customers: updated) else { return }
        customers = updated
    }

    @discardableResult
    func confirmReminderList(
        _ listID: String,
        for noteID: UUID,
        context: String,
        setCustomerDefault: Bool = false
    ) -> Bool {
        let selectedID = listID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedID.isEmpty, canWriteOrganization,
              let noteIndex = notes.firstIndex(where: { $0.id == noteID }) else { return false }

        var updatedNotes = notes
        updatedNotes[noteIndex].reminderListID = selectedID
        let customerID = updatedNotes[noteIndex].customerID
        var updatedCustomers = customers
        if setCustomerDefault,
           let customerID,
           let customerIndex = updatedCustomers.firstIndex(where: { $0.id == customerID }) {
            let oldDefault = updatedCustomers[customerIndex].defaultReminderListID
            var associated = updatedCustomers[customerIndex].reminderListIDs
            if let oldDefault, oldDefault != selectedID, !associated.contains(oldDefault) {
                associated.append(oldDefault)
            }
            associated.removeAll { $0 == selectedID }
            updatedCustomers[customerIndex].defaultReminderListID = selectedID
            updatedCustomers[customerIndex].reminderListIDs = associated
        }
        let sample = ReminderRoutingExample(
            noteID: noteID,
            customerID: customerID,
            listID: selectedID,
            context: context,
            confirmedAt: Date()
        )
        var examples = reminderRoutingExamples.filter { $0.noteID != noteID }
        examples.append(sample)
        if examples.count > 200 { examples.removeFirst(examples.count - 200) }

        // Both files use atomic replacement. If the organization write fails,
        // restore the earlier note selection so it cannot look confirmed without
        // its matching learning history.
        do {
            try writeMetadata(updatedNotes)
        } catch {
            present(error, action: "Speichern der Erinnerungsliste")
            return false
        }
        guard persistOrganization(customers: updatedCustomers, reminderRoutingExamples: examples) else {
            do {
                try writeMetadata(notes)
            } catch {
                // The explicit choice is already durable; reflect it in memory
                // and report the failure instead of overwriting it later.
                notes = sort(updatedNotes)
                present(error, action: "Wiederherstellen der vorherigen Listenwahl")
            }
            return false
        }
        notes = sort(updatedNotes)
        customers = updatedCustomers
        reminderRoutingExamples = examples
        return true
    }

    func reminderRoutingContext(for noteID: UUID, taskTitles: [String]) -> String {
        guard let note = notes.first(where: { $0.id == noteID }) else {
            return taskTitles.joined(separator: " ")
        }
        return ReminderRouting.context(note: note, taskTitles: taskTitles)
    }

    func reminderRoutingDecision(
        for noteID: UUID,
        taskTitles: [String],
        lists: [ReminderList],
        globalListID: String
    ) -> ReminderRoutingDecision {
        guard let note = notes.first(where: { $0.id == noteID }) else {
            return ReminderRoutingDecision(targetListID: nil, suggestedListID: nil,
                                           requiresConfirmation: true, reason: nil)
        }
        let customer = customer(for: note.customerID)
        return ReminderRouting.decide(
            note: note,
            customer: customer,
            examples: reminderRoutingExamples,
            taskTitles: taskTitles,
            lists: lists,
            globalListID: globalListID
        )
    }

    func customer(for id: UUID?) -> Customer? {
        guard let id else { return nil }
        return customers.first { $0.id == id }
    }

    func assignCustomer(_ customerID: UUID?, event: CalendarEventSnapshot?, to noteID: UUID) {
        guard canWriteOrganization,
              customerID == nil || customer(for: customerID) != nil,
              let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        var updatedNotes = notes
        updatedNotes[index].customerID = customerID
        updatedNotes[index].calendarEvent = event
        updatedNotes[index].updatedAt = Date()
        do {
            try writeMetadata(updatedNotes)
            notes = sort(updatedNotes)
        } catch {
            present(error, action: "Zuordnen des Kunden")
        }
    }

    func addPage(to noteID: UUID) -> UUID? {
        guard canWrite else { return nil }
        guard let noteIndex = notes.firstIndex(where: { $0.id == noteID }) else { return nil }

        let pageID = UUID()
        do {
            // Persist the page before making it visible in the metadata index.
            try writeDrawing(PKDrawing(), for: pageID)

            var updatedNotes = notes
            updatedNotes[noteIndex].pageIDs.append(pageID)
            updatedNotes[noteIndex].pageBackgrounds[pageID] = newPageBackground
            updatedNotes[noteIndex].updatedAt = Date()
            try writeMetadata(updatedNotes)
            notes = sort(updatedNotes)
            queueSearchIndexing(for: pageID, delay: 0)
            return pageID
        } catch {
            present(error, action: "Hinzufügen einer Seite")
            return nil
        }
    }

    @discardableResult
    func deletePage(_ pageID: UUID, from noteID: UUID) -> Bool {
        guard canWrite,
              let noteIndex = notes.firstIndex(where: { $0.id == noteID }),
              let pageIndex = notes[noteIndex].pageIDs.firstIndex(of: pageID),
              notes[noteIndex].pageIDs.count > 1 else { return false }

        var updatedNotes = notes
        updatedNotes[noteIndex].pageIDs.remove(at: pageIndex)
        updatedNotes[noteIndex].pageBackgrounds.removeValue(forKey: pageID)
        updatedNotes[noteIndex].updatedAt = Date()
        let firstPageChanged = pageIndex == 0
        var replacementThumbnailDrawing: PKDrawing?

        do {
            if firstPageChanged, let newFirstPageID = updatedNotes[noteIndex].pageIDs.first {
                guard let newFirstPageURL = drawingURL(for: newFirstPageID) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                replacementThumbnailDrawing = try PKDrawing(data: Data(contentsOf: newFirstPageURL))
            }
            // Commit the index first. If this fails, every page and its artifacts
            // remain reachable and the editor can safely resume the current page.
            try writeMetadata(updatedNotes)
            notes = sort(updatedNotes)
            removeSearchPage(pageID)
            removeCloudPageEditDate(pageID)
        } catch {
            present(error, action: "Löschen der Seite")
            return false
        }

        if let replacementThumbnailDrawing {
            do {
                try writeThumbnail(for: replacementThumbnailDrawing, noteID: noteID)
            } catch {
                // Never leave the deleted page visible as the note's preview. A
                // missing cache is regenerated by thumbnail(for:) on the next read.
                try? removeArtifact(at: thumbnailURL(for: noteID))
                present(error, action: "Aktualisieren der Vorschau")
            }
        }

        do {
            try removeArtifact(at: drawingURL(for: pageID))
            try removeArtifact(at: recognizedTasksURL(for: pageID))
            if pageID != noteID {
                try removeArtifact(at: thumbnailURL(for: pageID))
            }
            unreadableDrawings.remove(pageID)
            unreadableTaskFiles.remove(pageID)
        } catch {
            // The metadata deletion has already succeeded. Artifact cleanup and the
            // note thumbnail are recoverable, so keep the UI on the remaining page.
            present(error, action: "Entfernen der Seitendateien")
        }
        return true
    }

    func drawing(for id: UUID) -> PKDrawing {
        guard note(containingPage: id) != nil else { return PKDrawing() }
        guard let drawingURL = drawingURL(for: id) else { return PKDrawing() }
        // Cloud metadata can arrive before the page asset. An absent file is not
        // a corrupt drawing and must not permanently block the later import.
        guard fileManager.fileExists(atPath: drawingURL.path) else { return PKDrawing() }

        do {
            let data = try Data(contentsOf: drawingURL)
            return try PKDrawing(data: data)
        } catch {
            unreadableDrawings.insert(id)
            present(error, action: "Lesen der Zeichnung")
            return PKDrawing()
        }
    }

    func background(for pageID: UUID) -> NotePageBackground {
        note(containingPage: pageID)?.pageBackgrounds[pageID] ?? .plain
    }

    func renderedPage(for pageID: UUID) -> UIImage? {
        guard let note = note(containingPage: pageID) else { return nil }
        let drawing = drawing(for: pageID)
        guard !unreadableDrawings.contains(pageID) else { return nil }
        return NotePagePresentation.composite(
            rawDrawingImage: makeThumbnail(from: drawing, scale: 2),
            background: background(for: pageID),
            header: NotePagePresentation.header(for: note, pageID: pageID),
            scale: 2
        )
    }

    func saveDrawing(_ drawing: PKDrawing, for id: UUID) {
        guard let owningNote = note(containingPage: id), canWrite else { return }
        guard !waitingForCloudPages.contains(id) else {
            errorMessage = "Diese Zeichnung ist noch nicht verfügbar und blieb unverändert."
            return
        }
        guard !unreadableDrawings.contains(id) else {
            errorMessage = "Diese Zeichnung konnte nicht gelesen werden und blieb unverändert."
            return
        }

        var drawingWasWritten = false
        do {
            try writeDrawing(drawing, for: id)
            drawingWasWritten = true
            if owningNote.pageIDs.first == id {
                try writeThumbnail(for: drawing, noteID: owningNote.id)
            }

            var updatedNotes = notes
            guard let index = updatedNotes.firstIndex(where: { $0.id == owningNote.id }) else { return }
            updatedNotes[index].updatedAt = Date()
            try writeMetadata(updatedNotes)
            notes = sort(updatedNotes)
            queueSearchIndexing(for: id, delay: 0.7)
        } catch {
            if drawingWasWritten { queueSearchIndexing(for: id, delay: 0.7) }
            present(error, action: "Speichern der Zeichnung")
        }
    }

    func deleteNote(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }), canWrite else { return }

        do {
            let updatedNotes = notes.filter { $0.id != id }
            // Commit the index before removing artifacts, so a failed metadata write
            // never removes a note that is still listed.
            try writeMetadata(updatedNotes)
            notes = sort(updatedNotes)
            for pageID in note.pageIDs { removeSearchPage(pageID) }
            for pageID in note.pageIDs { removeCloudPageEditDate(pageID) }

            for pageID in note.pageIDs {
                try removeArtifact(at: drawingURL(for: pageID))
                try removeArtifact(at: recognizedTasksURL(for: pageID))
                unreadableDrawings.remove(pageID)
                unreadableTaskFiles.remove(pageID)
            }
            try removeArtifact(at: thumbnailURL(for: note.id))
        } catch {
            present(error, action: "Entfernen der Notizdateien")
        }
    }

    func recognizedTasks(for id: UUID) -> [RecognizedTask] {
        guard note(containingPage: id) != nil,
              let url = recognizedTasksURL(for: id),
              fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONDecoder().decode([RecognizedTask].self, from: Data(contentsOf: url))
        } catch {
            unreadableTaskFiles.insert(id)
            present(error, action: "Lesen der erkannten Aufgaben")
            return []
        }
    }

    func saveRecognizedTasks(_ tasks: [RecognizedTask], for id: UUID) {
        guard note(containingPage: id) != nil, canWrite,
              !unreadableTaskFiles.contains(id),
              let url = recognizedTasksURL(for: id) else { return }
        do {
            try JSONEncoder().encode(tasks).write(to: url, options: .atomic)
            markCloudPageEdited(id)
            searchTaskTitles[id] = tasks.filter(\.isPresent).map(\.title)
            objectWillChange.send()
            cloudSync?.queuePage(id)
        } catch {
            present(error, action: "Speichern der erkannten Aufgaben")
        }
    }

    func thumbnail(for id: UUID) -> UIImage? {
        guard let note = notes.first(where: { $0.id == id }),
              let firstPageID = note.pageIDs.first else { return nil }
        guard let url = thumbnailURL(for: id) else { return nil }

        do {
            guard fileManager.fileExists(atPath: url.path) else {
                return thumbnailFromDrawing(for: note, firstPageID: firstPageID, at: url)
            }
            let data = try Data(contentsOf: url)
            guard let image = UIImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Existing opaque caches predate page backgrounds and hide the
            // header/lines. Rebuild those once from the source drawing.
            if (note.pageBackgrounds[firstPageID] == nil && !upgradedLegacyThumbnails.contains(id)) ||
                image.cgImage?.alphaInfo == CGImageAlphaInfo.none ||
                image.cgImage?.alphaInfo == .noneSkipLast ||
                image.cgImage?.alphaInfo == .noneSkipFirst {
                let drawing = drawing(for: firstPageID)
                guard !unreadableDrawings.contains(firstPageID) else { return nil }
                let transparentImage = makeThumbnail(from: drawing)
                try writePNG(transparentImage, to: url)
                upgradedLegacyThumbnails.insert(id)
                return NotePagePresentation.composite(
                    rawDrawingImage: transparentImage,
                    background: background(for: firstPageID),
                    header: NotePagePresentation.header(for: note, pageID: firstPageID)
                )
            }
            return NotePagePresentation.composite(
                rawDrawingImage: image,
                background: background(for: firstPageID),
                header: NotePagePresentation.header(for: note, pageID: firstPageID)
            )
        } catch {
            present(error, action: "Lesen der Vorschau")
            // A thumbnail is a cache. Regenerate it from the source drawing without
            // touching either persisted file if its source cannot be read.
            let drawing = drawing(for: firstPageID)
            guard !unreadableDrawings.contains(firstPageID) else { return nil }
            return thumbnailFromDrawing(for: note, firstPageID: firstPageID, at: url, drawing: drawing)
        }
    }

    private func thumbnailFromDrawing(for note: Note, firstPageID: UUID, at url: URL,
                                      drawing suppliedDrawing: PKDrawing? = nil) -> UIImage? {
        guard let sourceURL = drawingURL(for: firstPageID),
              fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        let drawing = suppliedDrawing ?? self.drawing(for: firstPageID)
        guard !unreadableDrawings.contains(firstPageID) else { return nil }
        let image = makeThumbnail(from: drawing)
        do {
            try writePNG(image, to: url)
        } catch {
            present(error, action: "Wiederherstellen der Vorschau")
        }
        return NotePagePresentation.composite(
            rawDrawingImage: image,
            background: background(for: firstPageID),
            header: NotePagePresentation.header(for: note, pageID: firstPageID)
        )
    }

    private var canWrite: Bool {
        guard storageIsUsable, storageURL != nil else {
            if errorMessage == nil {
                errorMessage = "Der Notizenspeicher ist nicht verfügbar."
            }
            return false
        }
        return true
    }

    private var canWriteOrganization: Bool {
        guard canWrite, organizationStorageIsUsable else {
            if errorMessage == nil {
                errorMessage = "Die Kundendaten konnten nicht gelesen werden und blieben unverändert."
            }
            return false
        }
        return true
    }

    private func note(containingPage pageID: UUID) -> Note? {
        notes.first { $0.pageIDs.contains(pageID) }
    }

    private func loadNotes() {
        guard let metadataURL else { return }
        guard fileManager.fileExists(atPath: metadataURL.path) else { return }

        do {
            let data = try Data(contentsOf: metadataURL)
            let decoded = try JSONDecoder().decode([Note].self, from: data)
            guard Set(decoded.map(\.id)).count == decoded.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            notes = sort(decoded)
        } catch {
            // Do not replace malformed metadata with an empty list: that would make
            // existing notes inaccessible and overwrite their only index on next save.
            storageIsUsable = false
            present(error, action: "Lesen der Notizliste")
        }
    }

    private var waitingForCloudPagesURL: URL? {
        storageURL?.appendingPathComponent("CloudWaitingPages.json")
    }

    private func loadWaitingForCloudPages() {
        guard let url = waitingForCloudPagesURL,
              fileManager.fileExists(atPath: url.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Set<UUID>.self, from: Data(contentsOf: url))
            // A page may have arrived just before a crash while the waiting-list
            // update was still pending. Its validated local file is authoritative.
            waitingForCloudPages = saved.filter { pageID in
                guard let drawingURL = drawingURL(for: pageID) else { return true }
                return !fileManager.fileExists(atPath: drawingURL.path)
            }
        } catch {
            storageIsUsable = false
            present(error, action: "Lesen der ausstehenden iCloud-Seiten")
        }
    }

    private func setWaitingForCloudPages(_ pages: Set<UUID>) throws {
        guard let url = waitingForCloudPagesURL else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(pages).write(to: url, options: .atomic)
        waitingForCloudPages = pages
    }

    private struct Organization: Codable {
        var customers: [Customer]
        var calendarCustomerMappings: [String: UUID]
        var automaticallyAssignCustomers: Bool
        var reminderRoutingExamples: [ReminderRoutingExample]

        private enum CodingKeys: String, CodingKey {
            case customers, calendarCustomerMappings, automaticallyAssignCustomers, reminderRoutingExamples
        }

        init(customers: [Customer], calendarCustomerMappings: [String: UUID],
             automaticallyAssignCustomers: Bool, reminderRoutingExamples: [ReminderRoutingExample]) {
            self.customers = customers
            self.calendarCustomerMappings = calendarCustomerMappings
            self.automaticallyAssignCustomers = automaticallyAssignCustomers
            self.reminderRoutingExamples = reminderRoutingExamples
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            customers = try container.decode([Customer].self, forKey: .customers)
            calendarCustomerMappings = try container.decode([String: UUID].self, forKey: .calendarCustomerMappings)
            automaticallyAssignCustomers = try container.decode(Bool.self, forKey: .automaticallyAssignCustomers)
            reminderRoutingExamples = try container.decodeIfPresent(
                [ReminderRoutingExample].self, forKey: .reminderRoutingExamples
            ) ?? []
        }
    }

    private struct CloudCustomer: Codable {
        let id: UUID
        let name: String
        let isArchived: Bool
    }

    private struct CloudOrganization: Codable {
        let customers: [CloudCustomer]
    }

    // Decode the wire value separately because Note normalizes duplicate page IDs.
    private struct CloudNotePageIDs: Decodable {
        let pageIDs: [UUID]?
    }

    private func loadOrganization() {
        guard let organizationURL,
              fileManager.fileExists(atPath: organizationURL.path) else { return }
        do {
            let organization = try JSONDecoder().decode(
                Organization.self,
                from: Data(contentsOf: organizationURL)
            )
            customers = organization.customers
            calendarCustomerMappings = organization.calendarCustomerMappings
            automaticallyAssignCustomers = organization.automaticallyAssignCustomers
            reminderRoutingExamples = organization.reminderRoutingExamples
        } catch {
            organizationStorageIsUsable = false
            present(error, action: "Lesen der Kundendaten")
        }
    }

    func searchResults(query: String, customerID: UUID? = nil) -> [NoteSearchResult] {
        searchResults(query: query, scope: customerID.map(NoteSearchScope.customer) ?? .all)
    }

    func searchResults(query: String, scope: NoteSearchScope) -> [NoteSearchResult] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { searchNormalized(String($0)) }
        guard !terms.isEmpty else { return [] }

        var results: [NoteSearchResult] = []
        for note in notes {
            switch scope {
            case .all: break
            case .customer(let id): guard note.customerID == id else { continue }
            case .unassigned: guard note.customerID == nil else { continue }
            }
            let customerName = customer(for: note.customerID)?.name
            let eventTitle = note.calendarEvent?.title
            for (index, pageID) in note.pageIDs.enumerated() {
                let handwriting = searchCheckedPages.contains(pageID) ? (searchPages[pageID]?.text ?? "") : ""
                let tasks = searchTaskTitles[pageID] ?? []
                let searchable = ([customerName, eventTitle, handwriting].compactMap { $0 } + tasks)
                    .joined(separator: "\n")
                let normalized = searchNormalized(searchable)
                guard terms.allSatisfy(normalized.contains) else { continue }

                let lines = ([handwriting] + tasks + [eventTitle, customerName].compactMap { $0 })
                    .flatMap { $0.components(separatedBy: .newlines) }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let matchingLine = lines.first { line in
                    terms.contains { searchNormalized(line).contains($0) }
                }
                let snippet = matchingLine ?? lines.first ?? ""
                results.append(NoteSearchResult(
                    noteID: note.id,
                    pageID: pageID,
                    pageNumber: index + 1,
                    customerName: customerName,
                    eventTitle: eventTitle,
                    snippet: String(snippet.prefix(180)),
                    updatedAt: note.updatedAt
                ))
            }
        }
        return results
    }

    func retrySearchIndexing() {
        let pages = Array(searchFailedPages)
        searchFailedPages.removeAll()
        searchIndexErrorMessage = nil
        for pageID in pages { queueSearchIndexing(for: pageID, delay: 0) }
    }

    private func searchNormalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }

    private var searchIndexURL: URL? {
        storageURL?.appendingPathComponent("SearchIndex.json")
    }

    private func loadSearchIndex() {
        guard let searchIndexURL, fileManager.fileExists(atPath: searchIndexURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode(
                NoteSearchIndex.File.self,
                from: Data(contentsOf: searchIndexURL)
            )
            if saved.version == NoteSearchIndex.version {
                searchPages = saved.pages
            }
        } catch {
            // A derived cache can be rebuilt without changing drawings or note metadata.
            searchIndexErrorMessage = "Der Suchindex wird neu aufgebaut: \(error.localizedDescription)"
        }
    }

    private func startSearchIndexing() {
        guard storageIsUsable else { return }
        let livePages = Set(notes.flatMap(\.pageIDs))
        searchPages = searchPages.filter { livePages.contains($0.key) }
        for pageID in livePages {
            if let url = recognizedTasksURL(for: pageID),
               let data = try? Data(contentsOf: url),
               let tasks = try? JSONDecoder().decode([RecognizedTask].self, from: data) {
                searchTaskTitles[pageID] = tasks.filter(\.isPresent).map(\.title)
            }
        }
        for pageID in notes.flatMap(\.pageIDs) {
            enqueueSearchPage(pageID)
        }
        updateSearchProgress()
        runSearchWorkerIfNeeded()
    }

    private func queueSearchIndexing(for pageID: UUID, delay: TimeInterval) {
        guard note(containingPage: pageID) != nil else { return }
        searchGenerations[pageID, default: 0] += 1
        searchCheckedPages.remove(pageID)
        searchFailedPages.remove(pageID)
        searchDebounceTasks[pageID]?.cancel()
        searchDebounceTasks.removeValue(forKey: pageID)
        searchPendingPages.removeAll { $0 == pageID }
        if delay > 0 {
            let generation = searchGenerations[pageID, default: 0]
            searchDebounceTasks[pageID] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled,
                      let self,
                      self.searchGenerations[pageID] == generation else { return }
                self.searchDebounceTasks.removeValue(forKey: pageID)
                self.enqueueSearchPage(pageID)
                self.updateSearchProgress()
                self.runSearchWorkerIfNeeded()
            }
        } else {
            enqueueSearchPage(pageID)
            runSearchWorkerIfNeeded()
        }
        updateSearchProgress()
    }

    private func enqueueSearchPage(_ pageID: UUID) {
        if !searchPendingPages.contains(pageID) { searchPendingPages.append(pageID) }
    }

    private func runSearchWorkerIfNeeded() {
        guard searchWorker == nil, !searchPendingPages.isEmpty else { return }
        searchWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.searchPendingPages.isEmpty {
                let pageID = self.searchPendingPages.removeFirst()
                guard self.note(containingPage: pageID) != nil,
                      let url = self.drawingURL(for: pageID) else { continue }
                let generation = self.searchGenerations[pageID, default: 0]
                do {
                    let data = try Data(contentsOf: url)
                    let hash = NoteSearchIndex.hash(data)
                    if self.searchPages[pageID]?.hash != hash {
                        let recognizer = self.searchRecognizer
                        let text = try await Task.detached(priority: .utility) {
                            try await recognizer(data)
                        }.value
                        guard self.searchGenerations[pageID, default: 0] == generation,
                              self.note(containingPage: pageID) != nil else { continue }
                        self.searchPages[pageID] = NoteSearchIndex.Entry(hash: hash, text: text)
                        try self.persistSearchIndex()
                    }
                    guard self.searchGenerations[pageID, default: 0] == generation else { continue }
                    self.searchCheckedPages.insert(pageID)
                    self.searchFailedPages.remove(pageID)
                } catch {
                    guard self.searchGenerations[pageID, default: 0] == generation,
                          self.note(containingPage: pageID) != nil else { continue }
                    self.searchPages.removeValue(forKey: pageID)
                    self.searchFailedPages.insert(pageID)
                    self.searchIndexErrorMessage = "Eine Seite konnte nicht für die Suche erfasst werden: \(error.localizedDescription)"
                }
                self.updateSearchProgress()
            }
            self.searchWorker = nil
            self.updateSearchProgress()
        }
    }

    private func removeSearchPage(_ pageID: UUID) {
        searchGenerations[pageID, default: 0] += 1
        searchDebounceTasks[pageID]?.cancel()
        searchDebounceTasks.removeValue(forKey: pageID)
        searchPendingPages.removeAll { $0 == pageID }
        searchCheckedPages.remove(pageID)
        searchFailedPages.remove(pageID)
        searchTaskTitles.removeValue(forKey: pageID)
        searchPages.removeValue(forKey: pageID)
        do { try persistSearchIndex() }
        catch { searchIndexErrorMessage = "Der Suchindex konnte nicht gespeichert werden: \(error.localizedDescription)" }
        updateSearchProgress()
    }

    private func persistSearchIndex() throws {
        guard let searchIndexURL else { throw CocoaError(.fileNoSuchFile) }
        let file = NoteSearchIndex.File(version: NoteSearchIndex.version, pages: searchPages)
        try JSONEncoder().encode(file).write(to: searchIndexURL, options: .atomic)
    }

    private func updateSearchProgress() {
        let total = notes.reduce(0) { $0 + $1.pageIDs.count }
        searchIndexProgress = NoteSearchIndexProgress(
            completed: searchCheckedPages.count,
            total: total,
            failed: searchFailedPages.count,
            isIndexing: searchWorker != nil || !searchPendingPages.isEmpty || !searchDebounceTasks.isEmpty
        )
    }

    @discardableResult
    private func persistOrganization(
        customers: [Customer]? = nil,
        calendarCustomerMappings: [String: UUID]? = nil,
        automaticallyAssignCustomers: Bool? = nil,
        reminderRoutingExamples: [ReminderRoutingExample]? = nil
    ) -> Bool {
        guard let organizationURL else { return false }
        let organization = Organization(
            customers: customers ?? self.customers,
            calendarCustomerMappings: calendarCustomerMappings ?? self.calendarCustomerMappings,
            automaticallyAssignCustomers: automaticallyAssignCustomers ?? self.automaticallyAssignCustomers,
            reminderRoutingExamples: reminderRoutingExamples ?? self.reminderRoutingExamples
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(organization).write(to: organizationURL, options: .atomic)
            if !applyingCloudChange { cloudSync?.queueOrganization() }
            return true
        } catch {
            present(error, action: "Speichern der Kundendaten")
            return false
        }
    }

    private func writeMetadata(_ notes: [Note]) throws {
        guard let metadataURL else { throw CocoaError(.fileNoSuchFile) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(notes).write(to: metadataURL, options: .atomic)
        if !applyingCloudChange { cloudSync?.queueNotes(previous: self.notes, current: notes) }
    }

    private func writeDrawing(_ drawing: PKDrawing, for id: UUID) throws {
        guard let url = drawingURL(for: id) else { throw CocoaError(.fileNoSuchFile) }
        try drawing.dataRepresentation().write(to: url, options: .atomic)
        if !applyingCloudChange, note(containingPage: id) != nil { markCloudPageEdited(id) }
        if !applyingCloudChange, note(containingPage: id) != nil { cloudSync?.queuePage(id) }
    }

    private func writeThumbnail(for drawing: PKDrawing, noteID: UUID) throws {
        guard let url = thumbnailURL(for: noteID) else { throw CocoaError(.fileNoSuchFile) }
        try writePNG(makeThumbnail(from: drawing), to: url)
    }

    private func writePNG(_ image: UIImage, to url: URL) throws {
        guard let pngData = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try pngData.write(to: url, options: .atomic)
    }

    private func makeThumbnail(from drawing: PKDrawing, scale: CGFloat = 1) -> UIImage {
        let bounds = CGRect(origin: .zero, size: Self.pageSize)
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        var thumbnail = UIImage()
        lightTraits.performAsCurrent {
            thumbnail = drawing.image(from: bounds, scale: scale)
        }
        return thumbnail
    }

    private func removeArtifact(at url: URL?) throws {
        guard let url, fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private var metadataURL: URL? {
        storageURL?.appendingPathComponent("notes.json")
    }

    private var organizationURL: URL? {
        storageURL?.appendingPathComponent("organization.json")
    }

    private func recognizedTasksURL(for id: UUID) -> URL? {
        storageURL?.appendingPathComponent("RecognizedTasks", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    private func drawingURL(for id: UUID) -> URL? {
        storageURL?.appendingPathComponent("Drawings", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).drawing")
    }

    private func thumbnailURL(for id: UUID) -> URL? {
        storageURL?.appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).png")
    }

    private func sort(_ notes: [Note]) -> [Note] {
        notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func present(_ error: Error, action: String) {
        errorMessage = "Fehler beim \(action): \(error.localizedDescription)"
    }

    private func startCloudSync() {
        let cloudSyncSetting = Bundle.main.object(forInfoDictionaryKey: "NotizenCloudSyncEnabled")
        let cloudSyncIsEnabled = (cloudSyncSetting as? NSNumber)?.boolValue
            ?? (cloudSyncSetting as? NSString)?.boolValue
            ?? false
        guard cloudSyncIsEnabled else {
            syncStatus = "iCloud-Sync ist deaktiviert"
            return
        }
        guard cloudSync == nil, storageIsUsable, let storageURL else { return }
        let sync = CloudSyncCoordinator(store: self, directory: storageURL)
        cloudSync = sync
        Task { await sync.start() }
    }

    func syncNow() async {
        if cloudSync == nil { startCloudSync() }
        await cloudSync?.syncNow()
    }

    func setCloudStatus(_ status: String) { syncStatus = status }

    private var cloudPageEditDatesURL: URL? {
        storageURL?.appendingPathComponent("CloudPageEditDates.json")
    }

    private func loadCloudPageEditDates() {
        guard let url = cloudPageEditDatesURL,
              let data = try? Data(contentsOf: url),
              let dates = try? JSONDecoder().decode([UUID: Date].self, from: data) else { return }
        cloudPageEditedAt = dates
    }

    private func markCloudPageEdited(_ id: UUID, at date: Date = Date()) {
        cloudPageEditedAt[id] = date
        persistCloudPageEditDates()
    }

    private func removeCloudPageEditDate(_ id: UUID) {
        cloudPageEditedAt.removeValue(forKey: id)
        persistCloudPageEditDates()
    }

    private func persistCloudPageEditDates() {
        guard let url = cloudPageEditDatesURL else { return }
        do { try JSONEncoder().encode(cloudPageEditedAt).write(to: url, options: .atomic) }
        catch { present(error, action: "Speichern des iCloud-Änderungszeitpunkts") }
    }

    func cloudLocalEditDate(for recordID: CKRecord.ID) -> Date? {
        let name = recordID.recordName
        if name.hasPrefix("note-"), let id = UUID(uuidString: String(name.dropFirst(5))) {
            return notes.first(where: { $0.id == id })?.updatedAt
        }
        if name.hasPrefix("page-"), let id = UUID(uuidString: String(name.dropFirst(5))) {
            return cloudPageEditedAt[id] ?? note(containingPage: id)?.updatedAt
        }
        return nil
    }

    func cloudRemoteEditDate(for record: CKRecord) -> Date? {
        if record.recordType == "Page" { return record["editedAt"] as? Date ?? record.modificationDate }
        if record.recordType == "Note", let data = record["payload"] as? Data {
            return (try? JSONDecoder().decode(Note.self, from: data))?.updatedAt
        }
        return record.modificationDate
    }

    func cloudRecord(for recordID: CKRecord.ID, zoneID: CKRecordZone.ID) -> CKRecord? {
        let name = recordID.recordName
        let record: CKRecord
        if name == "organization" {
            let organization = CloudOrganization(customers: customers.map {
                CloudCustomer(id: $0.id, name: $0.name, isArchived: $0.isArchived)
            })
            guard let data = try? JSONEncoder().encode(organization) else { return nil }
            record = CKRecord(recordType: "Organization", recordID: recordID)
            record["payload"] = data as NSData
        } else if name.hasPrefix("note-"), let id = UUID(uuidString: String(name.dropFirst(5))),
                  let note = notes.first(where: { $0.id == id }),
                  let data = try? JSONEncoder().encode(portableNote(note)) {
            record = CKRecord(recordType: "Note", recordID: recordID)
            record["payload"] = data as NSData
        } else if name.hasPrefix("page-"), let id = UUID(uuidString: String(name.dropFirst(5))),
                  note(containingPage: id) != nil, let drawingURL = drawingURL(for: id),
                  fileManager.fileExists(atPath: drawingURL.path) {
            record = CKRecord(recordType: "Page", recordID: recordID)
            record["drawing"] = CKAsset(fileURL: drawingURL)
            record["editedAt"] = (cloudLocalEditDate(for: recordID) ?? Date()) as NSDate
            let tasks = recognizedTasks(for: id).map { task -> RecognizedTask in
                var portable = task
                portable.reminderIdentifier = nil
                portable.reminderCalendarIdentifier = nil
                portable.reminderStatus = nil
                portable.reminderSyncError = nil
                portable.reminderLastSyncedIsChecked = nil
                portable.reminderDueDateSyncPending = false
                portable.reminderLastSyncedAlarmOffsetMinutes = nil
                portable.alarmSyncPending = false
                portable.reminderRemovalPending = false
                portable.reminderRestorePending = false
                return portable
            }
            let taskData = (try? JSONEncoder().encode(tasks)) ?? Data("[]".utf8)
            record["tasks"] = taskData as NSData
        } else { return nil }
        return record
    }

    private func portableNote(_ note: Note) -> Note {
        var result = note
        result.reminderListID = nil
        if let event = note.calendarEvent {
            result.calendarEvent = CalendarEventSnapshot(
                id: note.id.uuidString, eventIdentifier: nil, calendarIdentifier: "",
                calendarTitle: event.calendarTitle, title: event.title,
                startDate: event.startDate, endDate: event.endDate, isAllDay: event.isAllDay
            )
        }
        return result
    }

    func applyCloudRecord(_ record: CKRecord, preserveLocalOrganization: Bool = false) throws {
        guard storageIsUsable else { throw CocoaError(.fileReadCorruptFile) }
        applyingCloudChange = true
        defer { applyingCloudChange = false }
        switch record.recordType {
        case "Note":
            guard let data = record["payload"] as? Data,
                  var note = try? JSONDecoder().decode(Note.self, from: data),
                  let rawPages = try? JSONDecoder().decode(CloudNotePageIDs.self, from: data),
                  record.recordID.recordName == "note-\(note.id.uuidString)",
                  rawPages.pageIDs.map({ Set($0).count == $0.count }) ?? true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let previousPageIDs = notes.first(where: { $0.id == note.id })?.pageIDs ?? []
            if let local = notes.first(where: { $0.id == note.id }) {
                note.reminderListID = local.reminderListID
                if let remoteEvent = note.calendarEvent, let localEvent = local.calendarEvent,
                   remoteEvent.title == localEvent.title,
                   remoteEvent.startDate == localEvent.startDate,
                   remoteEvent.endDate == localEvent.endDate {
                    note.calendarEvent = localEvent
                }
            }
            var updated = notes.filter { $0.id != note.id }
            updated.append(note)
            var waiting = waitingForCloudPages
            waiting.subtract(previousPageIDs.filter { !note.pageIDs.contains($0) })
            for pageID in note.pageIDs {
                if let url = drawingURL(for: pageID), !fileManager.fileExists(atPath: url.path) {
                    waiting.insert(pageID)
                }
            }
            try setWaitingForCloudPages(waiting)
            try writeMetadata(updated)
            notes = sort(updated)
            for pageID in note.pageIDs { queueSearchIndexing(for: pageID, delay: 0) }
        case "Page":
            guard let id = UUID(uuidString: String(record.recordID.recordName.dropFirst(5))),
                  let asset = record["drawing"] as? CKAsset,
                  let source = asset.fileURL,
                  let destination = drawingURL(for: id) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let drawingData = try Data(contentsOf: source)
            _ = try PKDrawing(data: drawingData)
            try drawingData.write(to: destination, options: .atomic)
            unreadableDrawings.remove(id)
            if waitingForCloudPages.contains(id) {
                var waiting = waitingForCloudPages
                waiting.remove(id)
                try setWaitingForCloudPages(waiting)
            }
            let tasks = (record["tasks"] as? Data) ?? Data("[]".utf8)
            guard let tasksURL = recognizedTasksURL(for: id) else {
                throw CocoaError(.fileNoSuchFile)
            }
            var decoded = try JSONDecoder().decode([RecognizedTask].self, from: tasks)
            let local = recognizedTasks(for: id)
            for index in decoded.indices {
                // EventKit identifiers and outstanding operations belong to this
                // device. Only the drawing's desired presence travels via iCloud.
                decoded[index].reminderRemovalPending = false
                decoded[index].reminderRestorePending = false
                if let linked = local.first(where: { $0.id == decoded[index].id }) {
                    decoded[index].reminderIdentifier = linked.reminderIdentifier
                    decoded[index].reminderCalendarIdentifier = linked.reminderCalendarIdentifier
                    decoded[index].reminderStatus = linked.reminderStatus
                    decoded[index].reminderSyncError = linked.reminderSyncError
                    decoded[index].reminderLastSyncedIsChecked = linked.reminderLastSyncedIsChecked
                    decoded[index].reminderLastSyncedAlarmOffsetMinutes = linked.reminderLastSyncedAlarmOffsetMinutes
                    let needsLocalRemoval = decoded[index].wasRemovedFromDrawing
                        && linked.reminderIdentifier != nil
                        && linked.reminderStatus != .deleted
                    decoded[index].reminderRemovalPending = linked.reminderIdentifier != nil
                        && decoded[index].wasRemovedFromDrawing
                        && (linked.reminderRemovalPending || needsLocalRemoval)
                    // A remote Undo must not resurrect a reminder that had been
                    // deleted externally before its checkbox was removed.
                    decoded[index].reminderRestorePending = linked.reminderIdentifier != nil
                        && (linked.reminderRestorePending || needsLocalRemoval)
                    let localDateIsProtected = linked.dueDateSource == .manual
                        || linked.dueDateSource == .external
                    let remoteDateIsInferred = decoded[index].dueDateSource == nil
                        || decoded[index].dueDateSource == .automatic
                    if linked.reminderDueDateSyncPending || (localDateIsProtected && remoteDateIsInferred) {
                        decoded[index].dueDate = linked.dueDate
                        // Preserve the decision and its reference day together
                        // with a pending write, or a manual decision that remote
                        // handwriting recognition must not overwrite.
                        decoded[index].dueDateSource = linked.dueDateSource
                        decoded[index].dueDateReferenceDate = linked.dueDateReferenceDate
                        decoded[index].dueDateReferenceIsTrusted = linked.dueDateReferenceIsTrusted
                        decoded[index].dueDateLastAnalyzedText = linked.dueDateLastAnalyzedText
                        decoded[index].dueDateProposal = linked.dueDateProposal
                    }
                    decoded[index].reminderDueDateSyncPending = linked.reminderDueDateSyncPending
                        || (linked.reminderIdentifier != nil
                            && decoded[index].dueDate != linked.dueDate)
                    if linked.alarmSyncPending || (localDateIsProtected && remoteDateIsInferred) {
                        decoded[index].reminderAlarmOffsetMinutes = linked.reminderAlarmOffsetMinutes
                    }
                    decoded[index].alarmSyncPending = linked.alarmSyncPending
                        || (linked.reminderIdentifier != nil
                            && decoded[index].reminderAlarmOffsetMinutes != linked.reminderAlarmOffsetMinutes)
                }
            }
            try JSONEncoder().encode(decoded).write(to: tasksURL, options: .atomic)
            markCloudPageEdited(id, at: cloudRemoteEditDate(for: record) ?? Date())
            searchTaskTitles[id] = decoded.filter(\.isPresent).map(\.title)
            if let owningNote = note(containingPage: id) {
                if owningNote.pageIDs.first == id {
                    try? writeThumbnail(for: PKDrawing(data: drawingData), noteID: owningNote.id)
                }
                queueSearchIndexing(for: id, delay: 0)
            }
            cloudPageRevisions[id, default: 0] += 1
            objectWillChange.send()
        case "Organization":
            guard let data = record["payload"] as? Data,
                  let organization = try? JSONDecoder().decode(CloudOrganization.self, from: data),
                  Set(organization.customers.map(\.id)).count == organization.customers.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var merged = preserveLocalOrganization ? customers : []
            let remoteIDs = Set(organization.customers.map(\.id))
            merged.removeAll { remoteIDs.contains($0.id) }
            merged.append(contentsOf: organization.customers.map { cloud in
                let local = customers.first { $0.id == cloud.id }
                return Customer(id: cloud.id, name: cloud.name, isArchived: cloud.isArchived,
                                defaultReminderListID: local?.defaultReminderListID,
                                reminderListIDs: local?.reminderListIDs ?? [])
            })
            if preserveLocalOrganization {
                for customer in customers {
                    if let remote = organization.customers.first(where: { $0.id == customer.id }) {
                        if remote.name != customer.name || remote.isArchived != customer.isArchived {
                            let copy = Customer(id: UUID(), name: customer.name + " (Konfliktkopie)",
                                            isArchived: customer.isArchived,
                                            defaultReminderListID: customer.defaultReminderListID,
                                            reminderListIDs: customer.reminderListIDs)
                            merged.append(copy)
                        }
                    } else if !merged.contains(where: { $0.id == customer.id }) { merged.append(customer) }
                }
            }
            guard persistOrganization(customers: merged) else { throw CocoaError(.fileWriteUnknown) }
            customers = merged
            if preserveLocalOrganization { cloudSync?.queueOrganization() }
        default: break
        }
    }

    func applyCloudDeletion(_ recordID: CKRecord.ID) throws {
        guard storageIsUsable else { throw CocoaError(.fileReadCorruptFile) }
        applyingCloudChange = true
        defer { applyingCloudChange = false }
        let name = recordID.recordName
        if name.hasPrefix("note-"), let id = UUID(uuidString: String(name.dropFirst(5))),
           let note = notes.first(where: { $0.id == id }) {
            let updated = notes.filter { $0.id != id }
            try writeMetadata(updated)
            notes = sort(updated)
            var waiting = waitingForCloudPages
            waiting.subtract(note.pageIDs)
            try setWaitingForCloudPages(waiting)
            for pageID in note.pageIDs {
                removeSearchPage(pageID)
                removeCloudPageEditDate(pageID)
                try? removeArtifact(at: drawingURL(for: pageID))
                try? removeArtifact(at: recognizedTasksURL(for: pageID))
            }
            try? removeArtifact(at: thumbnailURL(for: id))
        } else if name.hasPrefix("page-"), let id = UUID(uuidString: String(name.dropFirst(5))) {
            if waitingForCloudPages.contains(id) {
                var waiting = waitingForCloudPages
                waiting.remove(id)
                try setWaitingForCloudPages(waiting)
            }
            removeCloudPageEditDate(id)
            try? removeArtifact(at: drawingURL(for: id))
            try? removeArtifact(at: recognizedTasksURL(for: id))
            removeSearchPage(id)
        }
    }

    func preserveCloudConflict(for recordID: CKRecord.ID) {
        let name = recordID.recordName
        guard name.hasPrefix("page-") || name.hasPrefix("note-") else { return }
        let sourceID = UUID(uuidString: String(name.dropFirst(5)))
        guard let sourceID,
              let original = notes.first(where: { $0.id == sourceID || $0.pageIDs.contains(sourceID) }) else { return }
        preserveCloudConflictCopy(of: original)
    }

    func preserveUnsavedCloudDrawing(_ drawing: PKDrawing, for pageID: UUID) {
        guard let original = note(containingPage: pageID) else { return }
        preserveCloudConflictCopy(of: original, overridingPage: pageID, drawing: drawing)
    }

    private func preserveCloudConflictCopy(of original: Note,
                                           overridingPage: UUID? = nil,
                                           drawing: PKDrawing? = nil) {
        var copy = Note(id: UUID(), createdAt: Date(), updatedAt: Date(),
                        pageIDs: original.pageIDs.map { _ in UUID() },
                        pageBackgrounds: [:], customerID: original.customerID,
                        calendarEvent: original.calendarEvent, reminderListID: original.reminderListID)
        do {
            for (oldID, newID) in zip(original.pageIDs, copy.pageIDs) {
                copy.pageBackgrounds[newID] = original.pageBackgrounds[oldID]
                guard let source = drawingURL(for: oldID), let destination = drawingURL(for: newID) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                if oldID == overridingPage, let drawing {
                    try drawing.dataRepresentation().write(to: destination, options: .atomic)
                } else {
                    try Data(contentsOf: source).write(to: destination, options: .atomic)
                }
                if let source = recognizedTasksURL(for: oldID), let destination = recognizedTasksURL(for: newID),
                   fileManager.fileExists(atPath: source.path) {
                    try Data(contentsOf: source).write(to: destination, options: .atomic)
                }
            }
            var updated = notes
            updated.append(copy)
            try writeMetadata(updated)
            notes = sort(updated)
        } catch { present(error, action: "Sichern einer Konfliktkopie") }
    }
}
