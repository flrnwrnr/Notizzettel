import SwiftUI

struct GalleryView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var reminderService: ReminderService
    @EnvironmentObject private var calendarService: CalendarService
    @EnvironmentObject private var obsidianExport: ObsidianExportService

    private enum Destination: Hashable {
        case note(UUID)
        case searchResult(noteID: UUID, pageID: UUID)
        case collection(NoteCollection)
    }

    @State private var path: [Destination] = []
    @State private var notePendingDeletion: Note?
    @State private var settingsArePresented = false
    @State private var collection: NoteCollection = .all
    @State private var notePendingAssignment: Note?
    @State private var isOverview = true
    @State private var overviewSearchText = ""
    @State private var collectionSearchText = ""
    @State private var searchesAllNotes = false

    private var usesIPadLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    private var visibleNotes: [Note] {
        store.notes.filter { note in
            switch collection {
            case .all: return true
            case .unassigned: return note.customerID == nil
            case .customer(let id): return note.customerID == id
            }
        }
    }

    private var canCreateNote: Bool {
        if isOverview { return true }
        if case .customer(let id) = collection {
            return store.customer(for: id).map { !$0.isArchived } ?? false
        }
        return true
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: usesIPadLayout ? 180 : 148,
                            maximum: usesIPadLayout ? 260 : 220), spacing: 18, alignment: .top)]
    }

    var body: some View {
        navigation
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.galleryBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if let message = obsidianExport.errorMessage {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(message)
                        .font(.footnote)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Erneut") { obsidianExport.retryPendingFailures() }
                        .font(.footnote.weight(.semibold))
                }
                .padding(12)
                .background(.regularMaterial)
            }
        }
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty { isOverview = true }
        }
        .sheet(isPresented: $settingsArePresented) {
            NavigationStack {
                SettingsView()
            }
            .environmentObject(reminderService)
        }
        .sheet(item: $notePendingAssignment) { note in
            NoteAssignmentView(noteID: note.id)
        }
        .alert(
            "Notiz löschen?",
            isPresented: deletionAlertIsPresented,
            presenting: notePendingDeletion
        ) { note in
            Button("Löschen", role: .destructive) {
                store.deleteNote(note.id)
                notePendingDeletion = nil
                if let last = path.last {
                    switch last {
                    case .note(let id) where id == note.id:
                        path.removeLast()
                    case .searchResult(let id, _) where id == note.id:
                        path.removeLast()
                    default:
                        break
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {
                notePendingDeletion = nil
            }
        } message: { note in
            if note.pageIDs.contains(where: { pageID in
                store.recognizedTasks(for: pageID).contains(where: { $0.reminderIdentifier != nil })
            }) {
                Text("Die Notiz wird dauerhaft gelöscht. Bereits erstellte Apple Erinnerungen bleiben erhalten.")
            } else {
                Text("Die Notiz wird dauerhaft gelöscht.")
            }
        }
        .alert("Ein Fehler ist aufgetreten", isPresented: errorAlertIsPresented) {
            Button("OK") {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "Unbekannter Fehler")
        }
        .tint(.primary)
    }

    private var navigation: some View {
        NavigationStack(path: $path) {
            Group {
                if overviewSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 0) {
                        if store.searchIndexProgress.isIndexing || store.searchIndexProgress.failed > 0 {
                            searchIndexStatus
                                .padding(.horizontal, 20)
                        }
                        overview
                    }
                } else {
                    searchResults(for: overviewSearchText, in: .all, searchesAllNotes: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.galleryBackground.ignoresSafeArea())
            .navigationTitle("Übersicht")
            .searchable(text: $overviewSearchText, prompt: "Alle Notizen durchsuchen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        settingsArePresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Einstellungen")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(action: createNote) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Neue Notiz")
                    .disabled(!canCreateNote)
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .note(let noteID):
                    NoteEditorView(noteID: noteID)
                case .searchResult(let noteID, let pageID):
                    NoteEditorView(noteID: noteID, initialPageID: pageID)
                case .collection(let selectedCollection):
                    collectionPage(selectedCollection)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.galleryBackground.ignoresSafeArea())
    }

    private func collectionPage(_ selectedCollection: NoteCollection) -> some View {
        Group {
            if !collectionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults(
                    for: collectionSearchText,
                    in: selectedCollection,
                    searchesAllNotes: searchesAllNotes
                )
            } else if visibleNotes.isEmpty {
                emptyState
            } else {
                notesGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.galleryBackground.ignoresSafeArea())
        .navigationTitle(title(for: selectedCollection))
        .searchable(text: $collectionSearchText, prompt: "In diesem Ordner suchen")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    settingsArePresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Einstellungen")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: createNote) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Neue Notiz")
                .disabled(!canCreateNote)
            }
        }
        .onAppear {
            collection = selectedCollection
            isOverview = false
        }
    }

    private func searchResults(
        for query: String,
        in selectedCollection: NoteCollection,
        searchesAllNotes: Bool
    ) -> some View {
        let scope: NoteSearchScope
        if searchesAllNotes {
            scope = .all
        } else {
            switch selectedCollection {
            case .all: scope = .all
            case .unassigned: scope = .unassigned
            case .customer(let id): scope = .customer(id)
            }
        }
        let results = store.searchResults(query: query, scope: scope)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if selectedCollection != .all {
                    Toggle("Alle Notizen durchsuchen", isOn: $searchesAllNotes)
                        .font(.subheadline)
                        .padding(.bottom, 4)
                }

                searchIndexStatus

                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(results) { result in
                        NavigationLink(value: Destination.searchResult(noteID: result.noteID, pageID: result.pageID)) {
                            searchResultRow(result)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .refreshable {
            await store.syncNow()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.galleryBackground)
    }

    @ViewBuilder
    private var searchIndexStatus: some View {
        let progress = store.searchIndexProgress
        if progress.isIndexing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Handschrift wird erfasst: \(progress.completed) von \(progress.total) Seiten")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
        if progress.failed > 0, !progress.isIndexing {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text("\(progress.failed) Seiten konnten nicht erfasst werden.")
                    .font(.footnote)
                Spacer(minLength: 0)
                Button("Erneut versuchen") { store.retrySearchIndexing() }
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        }
    }

    private func searchResultRow(_ result: NoteSearchResult) -> some View {
        let note = store.notes.first(where: { $0.id == result.noteID })
        let customer = store.customer(for: note?.customerID)
        return HStack(alignment: .top, spacing: 14) {
            SearchPageThumbnail(pageID: result.pageID, updatedAt: result.updatedAt)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: customer?.isArchived == true ? "archivebox" : "folder")
                    Text(result.customerName ?? "Ohne Zuordnung")
                        .lineLimit(1)
                    if customer?.isArchived == true {
                        Text("Archiv")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.weight(.semibold))

                if let eventTitle = result.eventTitle, !eventTitle.isEmpty {
                    Label(eventTitle, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("Seite \(result.pageNumber) · \(result.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !result.snippet.isEmpty {
                    Text(result.snippet)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func title(for collection: NoteCollection) -> String {
        switch collection {
        case .all: return "Alle Notizen"
        case .unassigned: return "Ohne Zuordnung"
        case .customer(let id): return store.customer(for: id)?.name ?? "Kunde"
        }
    }

    private var overview: some View {
        CustomerFolderOverview(
            openCollection: { selectedCollection in
                collection = selectedCollection
                collectionSearchText = ""
                searchesAllNotes = false
                path.append(.collection(selectedCollection))
            },
            noteDestination: { note in
                AnyView(
                    Button {
                        path.append(.note(note.id))
                    } label: {
                        NoteCard(
                            note: note,
                            thumbnail: store.thumbnail(for: note.id),
                            customerName: nil
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        deleteButton(for: note)
                    }
                )
            }
        )
    }

    private var notesGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(visibleNotes) { note in
                    Button {
                        path.append(.note(note.id))
                    } label: {
                        NoteCard(
                            note: note,
                            thumbnail: store.thumbnail(for: note.id),
                            customerName: isOverview ? store.customer(for: note.customerID)?.name : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        deleteButton(for: note)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .refreshable {
            await store.syncNow()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.galleryBackground)
    }

    @ViewBuilder
    private func deleteButton(for note: Note) -> some View {
        Button(role: .destructive) {
            notePendingDeletion = note
        } label: {
            Label {
                Text("Löschen")
            } icon: {
                if let redTrash = UIImage(systemName: "trash")?.withTintColor(
                    .systemRed,
                    renderingMode: .alwaysOriginal
                ) {
                    Image(uiImage: redTrash).renderingMode(.original)
                } else {
                    Image(systemName: "trash")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.red)
                }
            }
            .foregroundStyle(.red)
        }
        .tint(.red)
    }

    private var emptyState: some View {
        GeometryReader { geometry in
            ScrollView {
                ContentUnavailableView {
                    Label("Noch keine Notizen", systemImage: "square.and.pencil")
                } description: {
                    Text(canCreateNote ? "Erstelle eine handschriftliche Notiz in dieser Ablage." : "Dieser Kunde ist archiviert. Du kannst ihn unter „Einstellungen“ → „Kunden verwalten“ wieder aktivieren.")
                } actions: {
                    if canCreateNote {
                        Button("Neue Notiz", action: createNote)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.always)
            .refreshable {
                await store.syncNow()
            }
        }
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { notePendingDeletion != nil },
            set: { isPresented in
                if !isPresented { notePendingDeletion = nil }
            }
        )
    }

    private var errorAlertIsPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { isPresented in
                if !isPresented { store.errorMessage = nil }
            }
        )
    }

    private func createNote() {
        guard canCreateNote else { return }
        let now = Date()
        let destination: NoteCollection = isOverview ? .all : collection
        let shouldReadCalendar: Bool
        switch destination {
        case .all, .customer(_):
            shouldReadCalendar = store.automaticallyAssignCustomers
        case .unassigned:
            shouldReadCalendar = false
        }
        let decision = CustomerAssignmentPolicy.decide(
            collection: destination,
            automatic: store.automaticallyAssignCustomers,
            events: shouldReadCalendar ? calendarService.assignmentEvents(at: now) : [],
            at: now, mappings: store.calendarCustomerMappings, customers: store.customers
        )
        guard let note = store.createNote(customerID: decision.customerID, event: decision.event) else { return }
        path.append(.note(note.id))
        if decision.needsChoice { notePendingAssignment = note }
    }
}

private struct SearchPageThumbnail: View {
    let pageID: UUID
    let updatedAt: Date

    @EnvironmentObject private var store: NoteStore
    @State private var image: UIImage?

    private var refreshID: String {
        "\(pageID.uuidString)-\(updatedAt.timeIntervalSince1970)"
    }

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "scribble")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 56, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
        .accessibilityHidden(true)
        .task(id: refreshID) {
            image = store.renderedPage(for: pageID)
        }
    }
}

private struct CustomerFolderOverview: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let openCollection: (NoteCollection) -> Void
    let noteDestination: (Note) -> AnyView

    private var columns: [GridItem] {
        let isWideIPad = UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
        return [GridItem(.adaptive(minimum: isWideIPad ? 180 : 148,
                                   maximum: isWideIPad ? 260 : 220), spacing: 18, alignment: .top)]
    }

    private var populatedCustomerIDs: Set<UUID> {
        Set(store.notes.compactMap(\.customerID))
    }

    private var activeCustomers: [Customer] {
        store.customers.filter { !$0.isArchived && populatedCustomerIDs.contains($0.id) }
    }

    private var archivedCustomers: [Customer] {
        store.customers.filter { $0.isArchived && populatedCustomerIDs.contains($0.id) }
    }

    private var unassignedNotes: [Note] {
        store.notes.filter { $0.customerID == nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if activeCustomers.isEmpty && unassignedNotes.isEmpty {
                    Text("Erstelle eine neue Notiz. Kundenordner erscheinen, sobald sie Notizen enthalten.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        if !activeCustomers.isEmpty {
                            LazyVGrid(columns: columns, spacing: 22) {
                                ForEach(activeCustomers) { customer in
                                    folderButton(for: customer, archived: false)
                                }
                            }
                        }

                        if !unassignedNotes.isEmpty {
                            LazyVGrid(columns: columns, spacing: 22) {
                                ForEach(unassignedNotes) { note in
                                    noteDestination(note)
                                }
                            }
                        }
                    }
                }

                if !archivedCustomers.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Archiv")
                            .font(.title3.bold())

                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(archivedCustomers) { customer in
                                folderButton(for: customer, archived: true)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .refreshable {
            await store.syncNow()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.galleryBackground)
    }

    private func folderButton(for customer: Customer, archived: Bool) -> some View {
        Button {
            openCollection(.customer(customer.id))
        } label: {
            CustomerFolderCard(
                customer: customer,
                noteCount: store.notes.filter { $0.customerID == customer.id }.count,
                archived: archived
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                openCollection(.customer(customer.id))
            } label: {
                Label("Öffnen", systemImage: "folder")
            }
        }
    }
}

private struct CustomerFolderCard: View {
    let customer: Customer
    let noteCount: Int
    let archived: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            FolderArtwork(archived: archived)
                .padding(.horizontal, 7)

            Text(customer.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(noteCount == 1 ? "1 Notiz" : "\(noteCount) Notizen")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(customer.name), \(noteCount == 1 ? "1 Notiz" : "\(noteCount) Notizen")")
        .accessibilityHint(archived ? "Archivierten Kunden öffnen" : "Kundenordner öffnen")
    }
}

private struct FolderArtwork: View {
    let archived: Bool

    var body: some View {
        Image("CustomerFolder")
            .resizable()
            .scaledToFit()
            .saturation(archived ? 0 : 1)
            .accessibilityHidden(true)
    }
}

private struct NoteCard: View {
    let note: Note
    let thumbnail: UIImage?
    let customerName: String?

    private var accessibilityEventDescription: String {
        guard let event = note.calendarEvent else { return "" }
        return ", \(event.title), \(event.startDate.formatted(date: .abbreviated, time: .omitted))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                Color.white

                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "scribble")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(NoteStore.pageSize.width / NoteStore.pageSize.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(.black.opacity(0.05), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.09), radius: 7, y: 3)

            if let customerName {
                Label(customerName, systemImage: "folder")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }

            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Label(
                note.pageIDs.count == 1 ? "1 Seite" : "\(note.pageIDs.count) Seiten",
                systemImage: "doc.on.doc"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(customerName.map { $0 + ", " } ?? "")Notiz\(accessibilityEventDescription), \(note.pageIDs.count == 1 ? "1 Seite" : "\(note.pageIDs.count) Seiten"), bearbeitet \(note.updatedAt.formatted(date: .long, time: .shortened))")
    }
}

extension Color {
    static let galleryBackground = Color(
        red: 246.0 / 255.0,
        green: 243.0 / 255.0,
        blue: 237.0 / 255.0
    )
}

#Preview {
    GalleryView()
        .environmentObject(NoteStore())
        .environmentObject(ReminderService())
        .environmentObject(CalendarService())
        .environmentObject(ObsidianExportService())
}
