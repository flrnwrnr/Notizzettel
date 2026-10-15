import Combine
import PencilKit
import SwiftUI
import UIKit

enum PageSwipeDecision {
    static func destinationIndex(
        translation: CGSize,
        currentIndex: Int,
        pageCount: Int
    ) -> Int? {
        guard (0..<pageCount).contains(currentIndex),
              abs(translation.width) >= 55,
              abs(translation.width) >= abs(translation.height) * 1.3 else { return nil }
        let destination = currentIndex + (translation.width < 0 ? 1 : -1)
        return (0..<pageCount).contains(destination) ? destination : nil
    }

    static func canvasAllowsPaging(
        allowsFingerDrawing: Bool,
        zoomedAtStart: Bool,
        hadMultipleTouches: Bool
    ) -> Bool {
        !allowsFingerDrawing && !zoomedAtStart && !hadMultipleTouches
    }
}

struct NoteEditorView: View {
    let noteID: UUID
    let initialPageID: UUID?

    init(noteID: UUID, initialPageID: UUID? = nil) {
        self.noteID = noteID
        self.initialPageID = initialPageID
    }

    @EnvironmentObject private var store: NoteStore
    @State private var assignmentIsPresented = false
    @State private var selectedPageID: UUID?
    @State private var isChangingPage = false
    @State private var preparePageChange: (() async -> Void)?
    @State private var recoverPageChange: (() -> Void)?
    @State private var flushCurrentDrawing: (() -> Void)?
    @State private var resumeReminderPrompt: (() -> Void)?
    @State private var pageOverviewIsPresented = false
    @State private var overviewAction: PageOverviewAction?
    @State private var focusedTask: NoteTaskFocus?

    private enum PageOverviewAction {
        case select(UUID)
    }

    private var pageIDs: [UUID] {
        store.notes.first(where: { $0.id == noteID })?.pageIDs ?? [noteID]
    }

    private var currentPageID: UUID {
        if let selectedPageID, pageIDs.contains(selectedPageID) {
            return selectedPageID
        }
        if let initialPageID, pageIDs.contains(initialPageID) {
            return initialPageID
        }
        return pageIDs.first ?? noteID
    }
    private var currentPageIndex: Int { pageIDs.firstIndex(of: currentPageID) ?? 0 }

    private var currentPagePresentation: NotePagePresentation? {
        guard let note = store.notes.first(where: { $0.id == noteID }) else { return nil }
        return NotePagePresentation.header(for: note, pageID: currentPageID)
    }

    var body: some View {
        NotePageEditorView(
            noteID: currentPageID,
            parentNoteID: noteID,
            presentation: currentPagePresentation,
            background: store.background(for: currentPageID),
            pageIndex: currentPageIndex,
            pageCount: pageIDs.count,
            onNavigate: { index in
                if let index, pageIDs.indices.contains(index) {
                    changePage(to: pageIDs[index])
                } else if index == nil {
                    changePage(to: nil)
                }
            },
            onShowOverview: showPageOverview,
            pageOverviewIsPresented: pageOverviewIsPresented,
            focusedTask: focusedTask,
            onShowTask: { pageID, bounds in
                focusedTask = NoteTaskFocus(pageID: pageID, bounds: bounds)
                if pageID != currentPageID { changePage(to: pageID) }
            },
            onFocusApplied: { focusedTask = nil }
        ) { prepare, recover, flush, resumePrompt in
            preparePageChange = prepare
            recoverPageChange = recover
            flushCurrentDrawing = flush
            resumeReminderPrompt = resumePrompt
        }
        .id(currentPageID)
        .allowsHitTesting(!isChangingPage)
        .safeAreaInset(edge: .top, spacing: 0) {
            Button {
                assignmentIsPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    let note = store.notes.first { $0.id == noteID }
                    let customer = store.customer(for: note?.customerID)
                    Text(customer.map { $0.name + ($0.isArchived ? " · Archiv" : "") } ?? "Kunde zuordnen")
                        .lineLimit(1)
                    if note?.calendarEvent != nil {
                        Image(systemName: "calendar")
                    }
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption)
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: 640)
                .background(Color.editorBackground)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Kunde und Terminkontext")
            .accessibilityValue(store.customer(for: store.notes.first { $0.id == noteID }?.customerID)?.name ?? "Ohne Zuordnung")
        }
        .background(Color.editorBackground.ignoresSafeArea())
        .sheet(isPresented: $assignmentIsPresented) {
            NoteAssignmentView(noteID: noteID)
        }
        .sheet(isPresented: $pageOverviewIsPresented, onDismiss: finishPageOverview) {
            PageOverviewSheet(
                currentPageID: currentPageID,
                pageIDs: pageIDs,
                onSelect: { pageID in
                    overviewAction = .select(pageID)
                    pageOverviewIsPresented = false
                },
                onDelete: { pageID, _ in
                    deletePage(pageID)
                }
            )
            .allowsHitTesting(!isChangingPage)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func showPageOverview() {
        guard !isChangingPage else { return }
        flushCurrentDrawing?()
        overviewAction = nil
        pageOverviewIsPresented = true
    }

    private func finishPageOverview() {
        let action = overviewAction
        overviewAction = nil
        switch action {
        case .select(let pageID):
            if pageID == currentPageID { resumeReminderPrompt?() }
            else { changePage(to: pageID) }
        case nil: resumeReminderPrompt?()
        }
    }

    private func changePage(to pageID: UUID?) {
        guard !isChangingPage, pageID != currentPageID else { return }
        guard let destination = pageID ?? store.addPage(to: noteID) else { return }
        // Finish persistence and reminder work before another page session can
        // read these files, including when the user immediately returns here.
        isChangingPage = true
        Task { @MainActor in
            await preparePageChange?()
            selectedPageID = destination
            isChangingPage = false
        }
    }

    private func deletePage(_ pageID: UUID) {
        guard !isChangingPage,
              let pageIndex = pageIDs.firstIndex(of: pageID),
              pageIDs.count > 1 else { return }
        if pageID != currentPageID {
            _ = store.deletePage(pageID, from: noteID)
            return
        }
        let destination = pageIndex > 0 ? pageIDs[pageIndex - 1] : pageIDs[pageIndex + 1]
        isChangingPage = true

        Task { @MainActor in
            await preparePageChange?()
            if store.deletePage(pageID, from: noteID) {
                selectedPageID = destination
            } else {
                recoverPageChange?()
            }
            isChangingPage = false
        }
    }
}

private struct NoteTaskFocus: Equatable {
    let token = UUID()
    let pageID: UUID
    let bounds: CGRect
}

private struct PageOverviewSheet: View {
    let currentPageID: UUID
    let pageIDs: [UUID]
    let onSelect: (UUID) -> Void
    let onDelete: (UUID, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pagePendingDeletion: (id: UUID, number: Int)?

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 20)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(Array(pageIDs.enumerated()), id: \.element) { index, pageID in
                        VStack(spacing: 6) {
                            Button { onSelect(pageID) } label: {
                                PageOverviewThumbnail(pageID: pageID)
                                    .aspectRatio(NotePagePresentation.pageSize, contentMode: .fit)
                                    .background(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 4)
                                            .strokeBorder(
                                                pageID == currentPageID ? Color.accentColor : Color.primary.opacity(0.12),
                                                lineWidth: pageID == currentPageID ? 2 : 1
                                            )
                                    }
                                    .shadow(color: .black.opacity(0.12), radius: 5, y: 3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Seite \(index + 1) auswählen")
                            .accessibilityAddTraits(pageID == currentPageID ? [.isSelected] : [])

                            HStack {
                                Text("Seite \(index + 1)")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if pageIDs.count > 1 {
                                    Button(role: .destructive) {
                                        pagePendingDeletion = (pageID, index + 1)
                                    } label: {
                                        Image(systemName: "trash")
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("Seite \(index + 1) löschen")
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.editorBackground)
            .navigationTitle("Seiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
            .alert(
                "Seite \(pagePendingDeletion?.number ?? 1) löschen?",
                isPresented: Binding(
                    get: { pagePendingDeletion != nil },
                    set: { if !$0 { pagePendingDeletion = nil } }
                ),
                presenting: pagePendingDeletion
            ) { pending in
                Button("Löschen", role: .destructive) {
                    onDelete(pending.id, pending.number)
                }
                Button("Abbrechen", role: .cancel) { pagePendingDeletion = nil }
            } message: { _ in
                Text("Bestehende Erinnerungen bleiben erhalten.")
            }
        }
    }
}

private struct PageOverviewThumbnail: View {
    let pageID: UUID

    @EnvironmentObject private var store: NoteStore
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.white.overlay {
                    Image(systemName: "doc")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: pageID) {
            guard let rendered = store.renderedPage(for: pageID) else { return }
            let size = CGSize(width: 150, height: 150 * NotePagePresentation.pageSize.height / NotePagePresentation.pageSize.width)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                rendered.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
}

private struct NotePageEditorView: View {
    let noteID: UUID
    let parentNoteID: UUID
    let presentation: NotePagePresentation?
    let background: NotePageBackground
    let pageIndex: Int
    let pageCount: Int
    let onNavigate: (Int?) -> Void
    let onShowOverview: () -> Void
    let pageOverviewIsPresented: Bool
    let focusedTask: NoteTaskFocus?
    let onShowTask: (UUID, CGRect) -> Void
    let onFocusApplied: () -> Void
    let registerPageChange: (
        @escaping () async -> Void,
        @escaping () -> Void,
        @escaping () -> Void,
        @escaping () -> Void
    ) -> Void

    @EnvironmentObject private var store: NoteStore
    @AppStorage("allowFingerDrawing") private var allowFingerDrawing = false
    @EnvironmentObject private var reminderService: ReminderService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var deviceDisplayScale
    @StateObject private var canvasSession = CanvasSession()
    @StateObject private var recognitionSession = TaskRecognitionSession()
    @State private var recognitionSheetIsPresented = false
    @State private var editorIsVisible = false
    @State private var appIsActive = true
    @State private var recognitionSessionIsConfigured = false
    @State private var pendingRecognitionFinish: Task<Void, Never>?
    @State private var pageZoom: CGFloat = 1
    @State private var pageOffset: CGSize = .zero
    @State private var dueDateTask: RecognizedTask?
    @State private var dueDateLayoutCache = TaskDueDateAnnotationCache()
    @State private var highlightedTaskBounds: CGRect?
    @State private var highlightedTaskToken: UUID?

    var body: some View {
        editorWithRoutingUpdates
            .onChange(of: store.customers) { _, _ in
                recognitionSession.refreshReminderRouting()
            }
            .onChange(of: reminderService.hasAccess) { _, _ in
                recognitionSession.reminderPreferencesDidChange()
            }
            .onChange(of: reminderService.statusRevision) { _, _ in
                Task { await recognitionSession.refreshReminderStatuses() }
            }
            .alert("Ein Fehler ist aufgetreten", isPresented: errorAlertIsPresented) {
                Button("OK") { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "Unbekannter Fehler")
            }
    }

    private var editorBase: some View {
        canvasBody
            .navigationTitle("Notiz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    pageNavigationBar
                    Color.editorBackground
                        .frame(height: canvasSession.toolPickerBottomInset)
                }
            }
            .onAppear(perform: editorDidAppear)
            .onDisappear(perform: editorDidDisappear)
            .sheet(isPresented: $recognitionSheetIsPresented) {
                TaskProposalsSheet(
                    session: recognitionSession,
                    parentNoteID: parentNoteID,
                    currentPageID: noteID,
                    onShowTask: onShowTask,
                    drawingForPage: { pageID in
                        pageID == noteID ? canvasSession.canvasView.drawing : store.drawing(for: pageID)
                    }
                )
            }
            .sheet(item: $dueDateTask) { task in
                TaskDueDateEditorSheet(task: task) { dueDate, alarmOffsetMinutes in
                    recognitionSession.updateDueDate(dueDate, for: task.id, alarmOffsetMinutes: alarmOffsetMinutes)
                }
            }
    }

    private var editorWithRoutingUpdates: some View {
        editorBase
            .onChange(of: pageOverviewIsPresented) { _, _ in updateToolPickerSuspension() }
            .onChange(of: recognitionSheetIsPresented) { _, _ in updateToolPickerSuspension() }
            .onChange(of: dueDateTask?.id) { _, _ in updateToolPickerSuspension() }
            .onChange(of: scenePhase) { _, newPhase in scenePhaseDidChange(newPhase) }
            .onChange(of: reminderService.automaticallyCreateReminders) { _, _ in
                recognitionSession.reminderPreferencesDidChange()
            }
            .onChange(of: reminderService.selectedListID) { _, _ in
                recognitionSession.refreshReminderRouting()
            }
            .onChange(of: reminderService.lists) { _, _ in
                recognitionSession.refreshReminderRouting()
            }
            .onChange(of: store.notes) { _, _ in
                recognitionSession.refreshReminderRouting()
            }
            .onChange(of: store.cloudPageRevisions[noteID, default: 0]) { _, _ in
                if let unsaved = canvasSession.unsavedDrawingForCloudRefresh() {
                    store.preserveUnsavedCloudDrawing(unsaved, for: noteID)
                }
                recognitionSession.deactivate()
                recognitionSessionIsConfigured = false
                configureRecognitionSession()
                canvasSession.reloadFromCloud(store.drawing(for: noteID))
            }
    }

    private var pageNavigationBar: some View {
        HStack(spacing: 2) {
            Button { onNavigate(pageIndex - 1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .disabled(pageIndex == 0)
            .accessibilityLabel("Vorherige Seite")

            Button(action: onShowOverview) {
                Text("\(pageIndex + 1) / \(pageCount)")
                    .font(.subheadline.monospacedDigit())
                    .frame(minWidth: 64, minHeight: 44)
            }
            .accessibilityLabel("Seitenübersicht")
            .accessibilityValue("Seite \(pageIndex + 1) von \(pageCount)")

            Button { onNavigate(pageIndex + 1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .disabled(pageIndex >= pageCount - 1)
            .accessibilityLabel("Nächste Seite")

            Button { onNavigate(nil) } label: {
                Image(systemName: "plus")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Seite hinzufügen")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .background(Color.editorBackground)
        .overlay(alignment: .top) { Color.primary.opacity(0.08).frame(height: 0.5) }
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { gesture in navigateIfSwiped(gesture.translation) }
        )
    }

    private func navigateIfSwiped(_ translation: CGSize) {
        guard let nextIndex = PageSwipeDecision.destinationIndex(
            translation: translation,
            currentIndex: pageIndex,
            pageCount: pageCount
        ) else { return }
        onNavigate(nextIndex)
    }

    private func updateToolPickerSuspension() {
        canvasSession.setToolPickerSuspended(pageOverviewIsPresented || recognitionSheetIsPresented || dueDateTask != nil)
    }

    private var canvasBody: some View {
        GeometryReader { geometry in
            let availableWidth = max(geometry.size.width - 24, 1)
            let availableHeight = max(geometry.size.height - 24, 1)
            let widthScale = availableWidth / NoteStore.pageSize.width
            let scale = min(widthScale, availableHeight / NoteStore.pageSize.height)
            let canvasDisplayScale = scale * pageZoom
            let annotationSizing = TaskCanvasAnnotationSizing.factors(for: UIDevice.current.userInterfaceIdiom)
            let markerSizeFactor = annotationSizing.marker
            let dateSizeFactor = annotationSizing.date
            let dateRects = dueDateLayoutCache.rects(
                for: recognitionSession.tasks.filter { !$0.isIgnored },
                in: canvasSession.canvasView.drawing,
                drawingRevision: canvasSession.drawingRevision,
                pageSize: NoteStore.pageSize,
                displayScale: canvasDisplayScale,
                markerSizeFactor: markerSizeFactor,
                dateSizeFactor: dateSizeFactor
            )
            let pageWidth = NoteStore.pageSize.width * canvasDisplayScale
            let pageHeight = NoteStore.pageSize.height * canvasDisplayScale
            let horizontalOverflow = max((pageWidth - geometry.size.width) / 2, 0)
            let verticalOverflow = max((pageHeight - geometry.size.height) / 2, 0)
            let displayedOffset = CGSize(
                width: min(max(pageOffset.width, -horizontalOverflow), horizontalOverflow),
                height: min(max(pageOffset.height, -verticalOverflow), verticalOverflow)
            )

            ZStack {
                Color.editorBackground

                ZStack {
                    Image(uiImage: NotePagePresentation.backgroundImage(
                        background: background,
                        header: presentation,
                        scale: min(4, ceil(canvasDisplayScale * deviceDisplayScale))
                    ))
                        .resizable()
                        .frame(width: pageWidth, height: pageHeight)
                        .accessibilityHidden(true)

                    ZStack {
                        PencilCanvas(
                            session: canvasSession,
                            allowFingerDrawing: allowFingerDrawing,
                            displayScale: canvasDisplayScale,
                            onPinch: { delta, location in
                                let newZoom = min(max(pageZoom * delta, 1), 4)
                                let zoomChange = newZoom - pageZoom
                                let newWidthOverflow = max(
                                    (NoteStore.pageSize.width * scale * newZoom - geometry.size.width) / 2, 0
                                )
                                let newHeightOverflow = max(
                                    (NoteStore.pageSize.height * scale * newZoom - geometry.size.height) / 2, 0
                                )
                                let pinchDistanceX: CGFloat = location.x - NoteStore.pageSize.width / 2
                                let pinchDistanceY: CGFloat = location.y - NoteStore.pageSize.height / 2
                                let zoomOffset: CGFloat = scale * zoomChange
                                let targetX: CGFloat = displayedOffset.width - pinchDistanceX * zoomOffset
                                let targetY: CGFloat = displayedOffset.height - pinchDistanceY * zoomOffset
                                pageOffset.width = min(max(targetX, -newWidthOverflow), newWidthOverflow)
                                pageOffset.height = min(max(targetY, -newHeightOverflow), newHeightOverflow)
                                pageZoom = newZoom
                            },
                            onPan: { translation in
                                let targetX = displayedOffset.width + translation.x * scale * pageZoom
                                let targetY = displayedOffset.height + translation.y * scale * pageZoom
                                pageOffset.width = min(max(targetX, -horizontalOverflow), horizontalOverflow)
                                pageOffset.height = min(max(targetY, -verticalOverflow), verticalOverflow)
                            },
                            isPageZoomed: pageZoom > 1.01,
                            onOneFingerPan: { translation in
                                let targetX = pageOffset.width + translation.x
                                let targetY = pageOffset.height + translation.y
                                pageOffset.width = min(max(targetX, -horizontalOverflow), horizontalOverflow)
                                pageOffset.height = min(max(targetY, -verticalOverflow), verticalOverflow)
                            },
                            onOneFingerSwipe: navigateIfSwiped,
                            tasks: recognitionSession.tasks.filter { !$0.isIgnored && !recognitionSession.isProvisional($0.id) },
                            dateRects: dateRects,
                            onTaskTap: { id in
                                dueDateTask = recognitionSession.tasks.first { $0.id == id && $0.isPresent && !$0.isIgnored }
                            }
                        )
                        .frame(width: pageWidth, height: pageHeight)

                        RecognitionOverlay(
                            tasks: recognitionSession.tasks.filter { !$0.isIgnored },
                            displayScale: canvasDisplayScale,
                            markerSizeFactor: markerSizeFactor,
                            dateSizeFactor: dateSizeFactor,
                            dateRects: dateRects,
                            editableTaskIDs: Set(recognitionSession.tasks.filter { !$0.isIgnored && !recognitionSession.isProvisional($0.id) }.map(\.id)),
                            onEditDate: { task in dueDateTask = task }
                        )
                        .allowsHitTesting(false)
                        .frame(width: NoteStore.pageSize.width, height: NoteStore.pageSize.height)
                        .scaleEffect(canvasDisplayScale)
                        .frame(width: pageWidth, height: pageHeight)

                        if let highlightedTaskBounds {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.yellow.opacity(0.15))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.orange, lineWidth: 2)
                                }
                                .frame(
                                    width: max(highlightedTaskBounds.width * canvasDisplayScale + 20, 34),
                                    height: max(highlightedTaskBounds.height * canvasDisplayScale + 20, 34)
                                )
                                .position(
                                    x: highlightedTaskBounds.midX * canvasDisplayScale,
                                    y: highlightedTaskBounds.midY * canvasDisplayScale
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(
                        width: NoteStore.pageSize.width * canvasDisplayScale,
                        height: NoteStore.pageSize.height * canvasDisplayScale
                    )
                }
                .frame(
                    width: pageWidth,
                    height: pageHeight
                )
                .background {
                    Color.white
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                }
                .offset(displayedOffset)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onAppear { focusTaskIfNeeded(in: geometry.size, scale: scale) }
            .onChange(of: focusedTask?.token) { _, _ in
                focusTaskIfNeeded(in: geometry.size, scale: scale)
            }
        }
    }

    private func focusTaskIfNeeded(in size: CGSize, scale: CGFloat) {
        guard let focusedTask, focusedTask.pageID == noteID else { return }
        let zoom: CGFloat = 2
        let width = NoteStore.pageSize.width * scale * zoom
        let height = NoteStore.pageSize.height * scale * zoom
        pageZoom = zoom
        let horizontalOverflow = max((width - size.width) / 2, 0)
        let verticalOverflow = max((height - size.height) / 2, 0)
        pageOffset = CGSize(
            width: min(max((NoteStore.pageSize.width / 2 - focusedTask.bounds.midX) * scale * zoom,
                           -horizontalOverflow), horizontalOverflow),
            height: min(max((NoteStore.pageSize.height / 2 - focusedTask.bounds.midY) * scale * zoom,
                            -verticalOverflow), verticalOverflow)
        )
        highlightedTaskBounds = focusedTask.bounds
        highlightedTaskToken = focusedTask.token
        onFocusApplied()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if highlightedTaskToken == focusedTask.token { highlightedTaskBounds = nil }
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                recognitionSheetIsPresented = true
            } label: {
                Image(systemName: "checklist")
            }
            .accessibilityLabel("Aufgaben")
            .overlay(alignment: .topTrailing) {
                if hasActionableTasks {
                    Circle().fill(.orange).frame(width: 7, height: 7).offset(x: 2, y: -2)
                }
            }

            Button {
                canvasSession.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!canvasSession.canUndo)
            .accessibilityLabel("Rückgängig")

            Button {
                canvasSession.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!canvasSession.canRedo)
            .accessibilityLabel("Wiederholen")
        }
    }

    private var hasActionableTasks: Bool {
        let pageIDs = store.notes.first(where: { $0.id == parentNoteID })?.pageIDs ?? [noteID]
        let tasks = pageIDs.flatMap { pageID in
            pageID == noteID ? recognitionSession.tasks : store.recognizedTasks(for: pageID)
        }
        return tasks.contains(where: TaskOverviewProjection.needsAction)
    }

    private func editorDidAppear() {
        registerPageChange({
            editorIsVisible = false
            canvasSession.flushPendingSave()
            canvasSession.recognizeCurrentDrawing()
            if let pendingRecognitionFinish {
                await pendingRecognitionFinish.value
            } else {
                await recognitionSession.finishPendingRecognition()
            }
            recognitionSession.deactivate()
            recognitionSessionIsConfigured = false
        }, {
            editorIsVisible = true
            appIsActive = scenePhase == .active
            configureRecognitionSession()
            canvasSession.editorDidAppear()
            Task { await recognitionSession.refreshReminderStatuses() }
        }, {
            canvasSession.flushPendingSave()
        }, {})
        editorIsVisible = true
        appIsActive = scenePhase == .active
        configureRecognitionSession()
        Task { await recognitionSession.refreshReminderStatuses() }
        canvasSession.configureRecognition(
            drawingActivityBegan: {
                recognitionSession.drawingActivityBegan()
            },
            drawingActivityEnded: { drawing in
                recognitionSession.drawingActivityEnded(drawing.dataRepresentation())
            },
            recognizeLive: { drawing in
                recognitionSession.drawingDidChange(
                    drawing.dataRepresentation(), automatically: false
                )
            },
            recognize: { drawing in
                recognitionSession.drawingDidChange(drawing.dataRepresentation())
            }
        )
        canvasSession.configureSave { drawing in
            store.saveDrawing(drawing, for: noteID)
        }
        canvasSession.loadIfNeeded(
            noteID: noteID,
            drawing: store.drawing(for: noteID)
        )
        canvasSession.editorDidAppear()
        updateToolPickerSuspension()
    }

    private func editorDidDisappear() {
        editorIsVisible = false
        canvasSession.editorDidDisappear()
        finishRecognitionAndDeactivateIfNeeded()
    }

    private func scenePhaseDidChange(_ newPhase: ScenePhase) {
        if newPhase == .active {
            appIsActive = true
            reminderService.refresh()
            configureRecognitionSession()
            canvasSession.recognizeCurrentDrawing()
            recognitionSession.reminderPreferencesDidChange()
            recognitionSession.retryReminderSync()
            Task { await recognitionSession.refreshReminderStatuses() }
            canvasSession.restoreToolPickerIfNeeded()
        } else {
            appIsActive = false
            finishRecognitionAndDeactivateIfNeeded()
        }
    }

    private var errorAlertIsPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { isPresented in
                if !isPresented { store.errorMessage = nil }
            }
        )
    }

    private func configureRecognitionSession() {
        recognitionSession.configureReminders(reminderService)
        recognitionSession.configure(
            noteID: noteID,
            savedTasks: store.recognizedTasks(for: noteID),
            legacyReferenceDate: store.notes.first(where: { $0.id == parentNoteID })?.createdAt
        ) { tasks, noteID in
            store.saveRecognizedTasks(tasks, for: noteID)
        }
        recognitionSession.seedRemovalEvidence(from: store.drawing(for: noteID).dataRepresentation())
        recognitionSession.configureReminderRouting { taskTitles in
            let otherTitles = (store.notes.first(where: { $0.id == parentNoteID })?.pageIDs ?? [])
                .filter { $0 != noteID }
                .flatMap { store.recognizedTasks(for: $0) }
                .filter { $0.isPresent && !$0.isIgnored }
                .map(\.title)
            return store.reminderRoutingDecision(
                for: parentNoteID,
                taskTitles: taskTitles + otherTitles,
                lists: reminderService.lists,
                globalListID: reminderService.selectedListID
            )
        }
        recognitionSessionIsConfigured = true
    }

    private func finishRecognitionAndDeactivateIfNeeded() {
        canvasSession.flushPendingSave()
        guard recognitionSessionIsConfigured,
              pendingRecognitionFinish == nil else { return }

        // PencilKit can deliver its final stroke after the last delegate callback.
        // Push the current canvas snapshot before forcing the recognition queue.
        canvasSession.recognizeCurrentDrawing()

        let session = recognitionSession
        let backgroundTask = RecognitionBackgroundTask()
        pendingRecognitionFinish = Task { @MainActor in
            defer {
                backgroundTask.end()
                pendingRecognitionFinish = nil
            }
            await session.finishPendingRecognition()
            guard !editorIsVisible || !appIsActive else { return }
            session.deactivate()
            recognitionSessionIsConfigured = false
        }
    }
}

@MainActor
private final class RecognitionBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Handschrifterkennung abschließen"
        ) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

}

@MainActor
private final class CanvasSession: NSObject, ObservableObject, PKToolPickerObserver {
    let canvasView = NoteCanvasView(frame: CGRect(origin: .zero, size: NoteStore.pageSize))

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var toolPickerBottomInset: CGFloat = 0
    @Published private(set) var drawingRevision = 0

    private let toolPicker = PKToolPicker()
    private var loadedNoteID: UUID?
    private var isLoadingDrawing = false
    private var isUsingDrawingTool = false
    private var isDirty = false
    private var isEditorVisible = false
    private var isCanvasObservingToolPicker = false
    private var isToolPickerSuspended = false
    private var saveTask: Task<Void, Never>?
    private var recognitionSnapshotTask: Task<Void, Never>?
    private var saveDrawing: ((PKDrawing) -> Void)?
    private var recognizeDrawing: ((PKDrawing) -> Void)?
    private var recognizeLiveDrawing: ((PKDrawing) -> Void)?
    private var drawingActivityBegan: (() -> Void)?
    private var drawingActivityEnded: ((PKDrawing) -> Void)?

    override init() {
        super.init()

        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.drawingPolicy = .pencilOnly
        canvasView.isScrollEnabled = false
        canvasView.alwaysBounceHorizontal = false
        canvasView.alwaysBounceVertical = false
        canvasView.bounces = false
        canvasView.contentInset = .zero
        canvasView.contentSize = NoteStore.pageSize
        canvasView.clipsToBounds = true
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 2.2)

        toolPicker.overrideUserInterfaceStyle = .light
        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.showsDrawingPolicyControls = false
        toolPicker.selectedTool = canvasView.tool
        toolPicker.addObserver(self)
        canvasView.didMoveToWindowHandler = { [weak self] in
            self?.canvasWindowDidChange()
        }
    }

    func configureSave(_ action: @escaping (PKDrawing) -> Void) {
        saveDrawing = action
    }

    func configureRecognition(
        drawingActivityBegan: @escaping () -> Void,
        drawingActivityEnded: @escaping (PKDrawing) -> Void,
        recognizeLive: @escaping (PKDrawing) -> Void,
        recognize: @escaping (PKDrawing) -> Void
    ) {
        self.drawingActivityBegan = drawingActivityBegan
        self.drawingActivityEnded = drawingActivityEnded
        recognizeLiveDrawing = recognizeLive
        recognizeDrawing = recognize
        recognize(canvasView.drawing)
    }

    func loadIfNeeded(noteID: UUID, drawing: PKDrawing) {
        guard loadedNoteID != noteID else { return }
        loadedNoteID = noteID
        isLoadingDrawing = true
        canvasView.drawing = drawing
        canvasView.undoManager?.removeAllActions()
        isLoadingDrawing = false
        isDirty = false
        drawingRevision &+= 1
        updateUndoState()
        recognizeDrawing?(drawing)
    }

    func unsavedDrawingForCloudRefresh() -> PKDrawing? {
        isDirty ? canvasView.drawing : nil
    }

    func reloadFromCloud(_ drawing: PKDrawing) {
        saveTask?.cancel()
        saveTask = nil
        isLoadingDrawing = true
        canvasView.drawing = drawing
        canvasView.undoManager?.removeAllActions()
        isLoadingDrawing = false
        isDirty = false
        drawingRevision &+= 1
        updateUndoState()
        recognizeDrawing?(drawing)
    }

    func drawingDidChange() {
        guard !isLoadingDrawing else { return }
        isDirty = true
        drawingRevision &+= 1
        // PencilKit may commit the final stroke after didEndUsingTool. Always
        // schedule from the committed drawing too, including lasso/eraser edits.
        if isUsingDrawingTool { scheduleRecognitionSnapshot() }
        else { recognizeDrawing?(canvasView.drawing) }
        updateUndoStateAfterCurrentEvent()
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard let self else { return }
            self.flushPendingSave()
        }
    }

    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        guard loadedNoteID != nil, isDirty else { return }
        isDirty = false
        saveDrawing?(canvasView.drawing)
    }

    private func scheduleRecognitionSnapshot() {
        guard recognitionSnapshotTask == nil else { return }
        recognitionSnapshotTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) }
            catch { return }
            guard let self else { return }
            self.recognitionSnapshotTask = nil
            guard self.isUsingDrawingTool else { return }
            self.recognizeLiveDrawing?(self.canvasView.drawing)
        }
    }

    func undo() {
        canvasView.undoManager?.undo()
        drawingDidChange()
        recognizeDrawing?(canvasView.drawing)
    }

    func redo() {
        canvasView.undoManager?.redo()
        drawingDidChange()
        recognizeDrawing?(canvasView.drawing)
    }

    func prepareCanvasForDisplay() {
        canvasView.didMoveToWindowHandler = { [weak self] in
            self?.canvasWindowDidChange()
        }
        canvasWindowDidChange()
    }

    func editorDidAppear() {
        isEditorVisible = true
        showToolPickerIfPossible()
    }

    func editorDidDisappear() {
        isEditorVisible = false
        hideToolPicker()
    }

    func restoreToolPickerIfNeeded() {
        showToolPickerIfPossible()
    }

    func setToolPickerSuspended(_ isSuspended: Bool) {
        isToolPickerSuspended = isSuspended
        if isSuspended {
            hideToolPicker()
        } else {
            showToolPickerIfPossible()
        }
    }

    func hideToolPicker() {
        toolPicker.setVisible(false, forFirstResponder: canvasView)
        updateToolPickerBottomInset()
    }

    func dismantleCanvas() {
        isEditorVisible = false
        hideToolPicker()
        if isCanvasObservingToolPicker {
            toolPicker.removeObserver(canvasView)
            isCanvasObservingToolPicker = false
        }
        canvasView.didMoveToWindowHandler = nil
        toolPickerBottomInset = 0
    }

    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        updateToolPickerBottomInset()
    }

    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {
        updateToolPickerBottomInset()
    }

    func updateUndoState() {
        canUndo = canvasView.undoManager?.canUndo ?? false
        canRedo = canvasView.undoManager?.canRedo ?? false
    }

    private func updateUndoStateAfterCurrentEvent() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.updateUndoState()
        }
    }

    private func canvasWindowDidChange() {
        if canvasView.window != nil {
            showToolPickerIfPossible()
        } else {
            hideToolPicker()
        }
    }

    private func showToolPickerIfPossible() {
        guard isEditorVisible, !isToolPickerSuspended, canvasView.window != nil else { return }
        attachToolPickerIfNeeded()
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        canvasView.becomeFirstResponder()
        updateToolPickerBottomInset()
    }

    private func attachToolPickerIfNeeded() {
        guard !isCanvasObservingToolPicker else { return }
        toolPicker.addObserver(canvasView)
        isCanvasObservingToolPicker = true
    }

    private func updateToolPickerBottomInset() {
        guard toolPicker.isVisible, let window = canvasView.window else {
            toolPickerBottomInset = 0
            return
        }

        let obscuredFrame = toolPicker.frameObscured(in: window)
        guard !obscuredFrame.isNull,
              !obscuredFrame.isEmpty,
              obscuredFrame.maxY >= window.bounds.maxY - 1 else {
            toolPickerBottomInset = 0
            return
        }
        toolPickerBottomInset = max(0, window.bounds.maxY - obscuredFrame.minY)
    }
}

private struct PencilCanvas: UIViewRepresentable {
    @ObservedObject var session: CanvasSession
    let allowFingerDrawing: Bool
    let displayScale: CGFloat
    let onPinch: (CGFloat, CGPoint) -> Void
    let onPan: (CGPoint) -> Void
    let isPageZoomed: Bool
    let onOneFingerPan: (CGPoint) -> Void
    let onOneFingerSwipe: (CGSize) -> Void
    let tasks: [RecognizedTask]
    let dateRects: [UUID: CGRect]
    let onTaskTap: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(session: session)
        coordinator.displayScale = displayScale
        coordinator.onPinch = onPinch
        coordinator.onPan = onPan
        coordinator.isPageZoomed = isPageZoomed
        coordinator.onOneFingerPan = onOneFingerPan
        coordinator.onOneFingerSwipe = onOneFingerSwipe
        coordinator.allowFingerDrawing = allowFingerDrawing
        coordinator.tasks = tasks
        coordinator.dateRects = dateRects
        coordinator.onTaskTap = onTaskTap
        return coordinator
    }

    func makeUIView(context: Context) -> PKCanvasView {
        session.canvasView.drawingPolicy = allowFingerDrawing ? .anyInput : .pencilOnly
        session.canvasView.delegate = context.coordinator
        context.coordinator.installGestures(on: session.canvasView)
        configureZoom(on: session.canvasView)
        session.prepareCanvasForDisplay()
        return session.canvasView
    }

    func updateUIView(_ canvasView: PKCanvasView, context: Context) {
        canvasView.drawingPolicy = allowFingerDrawing ? .anyInput : .pencilOnly
        context.coordinator.session = session
        context.coordinator.displayScale = displayScale
        context.coordinator.onPinch = onPinch
        context.coordinator.onPan = onPan
        context.coordinator.isPageZoomed = isPageZoomed
        context.coordinator.onOneFingerPan = onOneFingerPan
        context.coordinator.onOneFingerSwipe = onOneFingerSwipe
        context.coordinator.allowFingerDrawing = allowFingerDrawing
        context.coordinator.tasks = tasks
        context.coordinator.dateRects = dateRects
        context.coordinator.onTaskTap = onTaskTap
        configureZoom(on: canvasView)
        if canvasView.delegate !== context.coordinator {
            canvasView.delegate = context.coordinator
        }
    }

    private func configureZoom(on canvasView: PKCanvasView) {
        // PencilKit redraws strokes at its own zoom level. SwiftUI's scaleEffect
        // magnifies an already rendered canvas instead.
        canvasView.minimumZoomScale = 0.1
        canvasView.maximumZoomScale = 8
        // The editor handles pinches for the entire page. Disable UIScrollView's
        // own pinch so it cannot zoom the strokes separately from the paper.
        canvasView.pinchGestureRecognizer?.isEnabled = false
        if abs(canvasView.zoomScale - displayScale) > 0.001 {
            canvasView.zoomScale = displayScale
        }
    }

    static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
        uiView.delegate = nil
        coordinator.removeGestures(from: uiView)
        coordinator.session.dismantleCanvas()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        var session: CanvasSession
        var displayScale: CGFloat = 1
        var onPinch: ((CGFloat, CGPoint) -> Void)?
        var onPan: ((CGPoint) -> Void)?
        var isPageZoomed = false
        var allowFingerDrawing = false
        var onOneFingerPan: ((CGPoint) -> Void)?
        var onOneFingerSwipe: ((CGSize) -> Void)?
        var tasks: [RecognizedTask] = []
        var dateRects: [UUID: CGRect] = [:]
        var onTaskTap: ((UUID) -> Void)?
        private let pinchRecognizer = UIPinchGestureRecognizer()
        private let panRecognizer = UIPanGestureRecognizer()
        private let oneFingerPanRecognizer = PagePanGestureRecognizer()
        private let taskTapRecognizer = UITapGestureRecognizer()
        private var oneFingerPanStartedZoomed = false
        private var previousOneFingerTranslation = CGPoint.zero

        init(session: CanvasSession) {
            self.session = session
        }

        func installGestures(on canvasView: PKCanvasView) {
            pinchRecognizer.addTarget(self, action: #selector(handlePinch(_:)))
            pinchRecognizer.delegate = self
            pinchRecognizer.cancelsTouchesInView = false
            canvasView.addGestureRecognizer(pinchRecognizer)

            panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
            panRecognizer.minimumNumberOfTouches = 2
            panRecognizer.maximumNumberOfTouches = 2
            panRecognizer.delegate = self
            panRecognizer.cancelsTouchesInView = false
            canvasView.addGestureRecognizer(panRecognizer)

            oneFingerPanRecognizer.addTarget(self, action: #selector(handleOneFingerPan(_:)))
            oneFingerPanRecognizer.minimumNumberOfTouches = 1
            oneFingerPanRecognizer.maximumNumberOfTouches = 1
            oneFingerPanRecognizer.delegate = self
            oneFingerPanRecognizer.cancelsTouchesInView = false
            canvasView.addGestureRecognizer(oneFingerPanRecognizer)

            taskTapRecognizer.addTarget(self, action: #selector(handleTaskTap(_:)))
            taskTapRecognizer.delegate = self
            taskTapRecognizer.cancelsTouchesInView = true
            taskTapRecognizer.delaysTouchesBegan = true
            taskTapRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            canvasView.addGestureRecognizer(taskTapRecognizer)
            canvasView.drawingGestureRecognizer.require(toFail: taskTapRecognizer)
        }

        func removeGestures(from canvasView: PKCanvasView) {
            canvasView.removeGestureRecognizer(pinchRecognizer)
            canvasView.removeGestureRecognizer(panRecognizer)
            canvasView.removeGestureRecognizer(oneFingerPanRecognizer)
            canvasView.removeGestureRecognizer(taskTapRecognizer)
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            oneFingerPanRecognizer.markMultipleTouches()
            let location = recognizer.location(in: recognizer.view)
            onPinch?(recognizer.scale, CGPoint(x: location.x / displayScale, y: location.y / displayScale))
            recognizer.scale = 1
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed,
                  let view = recognizer.view else { return }
            oneFingerPanRecognizer.markMultipleTouches()
            let translation = recognizer.translation(in: view)
            onPan?(CGPoint(x: translation.x / displayScale, y: translation.y / displayScale))
            recognizer.setTranslation(.zero, in: view)
        }

        @objc private func handleOneFingerPan(_ recognizer: PagePanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            switch recognizer.state {
            case .began:
                oneFingerPanStartedZoomed = isPageZoomed
                previousOneFingerTranslation = translation
            case .changed:
                guard oneFingerPanStartedZoomed, !recognizer.hadMultipleTouches else { return }
                let delta = CGPoint(
                    x: translation.x - previousOneFingerTranslation.x,
                    y: translation.y - previousOneFingerTranslation.y
                )
                onOneFingerPan?(delta)
                previousOneFingerTranslation = translation
            case .ended:
                guard PageSwipeDecision.canvasAllowsPaging(
                    allowsFingerDrawing: allowFingerDrawing,
                    zoomedAtStart: oneFingerPanStartedZoomed,
                    hadMultipleTouches: recognizer.hadMultipleTouches
                ) else { return }
                onOneFingerSwipe?(CGSize(width: translation.x, height: translation.y))
            default:
                break
            }
        }

        @objc private func handleTaskTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            if let id = taskID(at: recognizer.location(in: view)) {
                onTaskTap?(id)
            }
        }

        private func taskID(at location: CGPoint) -> UUID? {
            let point = CGPoint(x: location.x / displayScale, y: location.y / displayScale)
            let markerRadius = 15 / max(displayScale, 0.2)
            for task in tasks where task.isPresent {
                let marker = CGPoint(x: task.bounds.minX, y: task.bounds.minY)
                if hypot(point.x - marker.x, point.y - marker.y) <= markerRadius
                    || dateRects[task.id]?.insetBy(dx: -5 / max(displayScale, 0.2), dy: -5 / max(displayScale, 0.2)).contains(point) == true {
                    return task.id
                }
            }
            return nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === oneFingerPanRecognizer { return !allowFingerDrawing }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer !== taskTapRecognizer && otherGestureRecognizer !== taskTapRecognizer
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard touch.type == .direct else { return false }
            if gestureRecognizer === taskTapRecognizer {
                return taskID(at: touch.location(in: session.canvasView)) != nil
            }
            return true
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            session.drawingDidChange()
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            session.invalidateRecognitionForDrawingActivity()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            session.flushPendingSave()
            session.recognizeCurrentDrawing()
        }
    }
}

private final class PagePanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var hadMultipleTouches = false

    func markMultipleTouches() {
        hadMultipleTouches = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let activeTouches = event.allTouches?.filter {
            $0.phase != .ended && $0.phase != .cancelled
        }
        if (activeTouches?.count ?? touches.count) > 1 {
            hadMultipleTouches = true
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        hadMultipleTouches = false
    }
}

private extension CanvasSession {
    func invalidateRecognitionForDrawingActivity() {
        isUsingDrawingTool = true
        drawingActivityBegan?()
    }

    func recognizeCurrentDrawing() {
        recognitionSnapshotTask?.cancel()
        recognitionSnapshotTask = nil
        let wasUsingDrawingTool = isUsingDrawingTool
        isUsingDrawingTool = false
        if wasUsingDrawingTool { drawingActivityEnded?(canvasView.drawing) }
        else { recognizeDrawing?(canvasView.drawing) }
    }
}

private struct RecognitionOverlay: View {
    let tasks: [RecognizedTask]
    let displayScale: CGFloat
    let markerSizeFactor: CGFloat
    let dateSizeFactor: CGFloat
    let dateRects: [UUID: CGRect]
    let editableTaskIDs: Set<UUID>
    let onEditDate: (RecognizedTask) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(tasks.filter(\.isPresent)) { task in
                TaskStatusMarker(state: task.markerState, displayScale: displayScale, sizeFactor: markerSizeFactor)
                    .position(x: task.bounds.minX, y: task.bounds.minY)
                    .accessibilityLabel("Fälligkeitsdatum für \(task.title)")
                    .accessibilityValue(task.dueDate.map { TaskDueDateAnnotationLayout.fullDate($0) } ?? "Kein Datum")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onEditDate(task) }
                    .accessibilityHidden(!editableTaskIDs.contains(task.id))

                if let dueDate = task.dueDate, let rect = dateRects[task.id] {
                    Text(TaskDueDateAnnotationLayout.shortDate(dueDate))
                        .font(.system(size: TaskDueDateAnnotationLayout.fontSize * dateSizeFactor, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.28))
                        .background(Color.white.opacity(0.8))
                        .fixedSize()
                        .position(x: rect.midX, y: rect.midY)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: NoteStore.pageSize.width, height: NoteStore.pageSize.height)
        .clipped()
    }
}

private struct TaskDueDateEditorSheet: View {
    let task: RecognizedTask
    let onSave: (TaskDueDate?, Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date
    @State private var selectedTime: Date
    @State private var includesTime: Bool
    @State private var alarmChoice: AlarmChoice

    private enum AlarmChoice: Int, CaseIterable, Identifiable {
        case never = -1
        case atDueDate = 0
        case fifteenMinutes = 15
        case oneHour = 60

        var id: Int { rawValue }
        var offsetMinutes: Int? { self == .never ? nil : rawValue }
        var title: String {
            switch self {
            case .never: "Nie"
            case .atDueDate: "Zur Fälligkeit"
            case .fifteenMinutes: "15 Minuten vorher"
            case .oneHour: "1 Stunde vorher"
            }
        }
    }

    init(task: RecognizedTask, onSave: @escaping (TaskDueDate?, Int?) -> Void) {
        self.task = task
        self.onSave = onSave
        let initialDueDate = task.dueDateProposal?.date ?? task.dueDate
        _selectedDate = State(initialValue: initialDueDate?.date ?? Date())
        _selectedTime = State(initialValue: initialDueDate?.hasTime == true ? initialDueDate!.date : Date())
        _includesTime = State(initialValue: initialDueDate?.hour != nil)
        _alarmChoice = State(initialValue: AlarmChoice(rawValue: task.reminderAlarmOffsetMinutes ?? -1) ?? .never)
    }

    private var editedDueDate: TaskDueDate {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: selectedDate)
        guard includesTime else {
            return TaskDueDate(year: day.year!, month: day.month!, day: day.day!)
        }
        let time = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
        return TaskDueDate(
            year: day.year!, month: day.month!, day: day.day!,
            hour: time.hour!, minute: time.minute!
        )
    }

    private var isSelectedDateValid: Bool {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: selectedDate)
        let time = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
        return TaskDueDate.isValid(
            year: day.year!, month: day.month!, day: day.day!,
            hour: includesTime ? time.hour : nil,
            minute: includesTime ? time.minute : nil
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(2)

                    DatePicker("Fällig am", selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .accessibilityLabel("Fälligkeitsdatum")

                    Toggle("Uhrzeit", isOn: $includesTime)
                    if includesTime {
                        DatePicker("Fällig um", selection: $selectedTime, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.compact)
                            .accessibilityLabel("Fälligkeitsuhrzeit")
                        Picker("Alarm", selection: $alarmChoice) {
                            ForEach(AlarmChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        if !isSelectedDateValid {
                            Text("Diese Uhrzeit gibt es an diesem Tag wegen der Zeitumstellung nicht.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let proposal = task.dueDateProposal {
                    Section("Datumsvorschlag prüfen") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("„\(proposal.sourceText)“")
                                .font(.body)
                                .accessibilityLabel("Erkannter Datumstext: \(proposal.sourceText)")
                            Text(proposal.reason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("Vorgeschlagen: \(TaskDueDateAnnotationLayout.fullDate(proposal.date))")
                                .font(.subheadline.weight(.medium))
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        Button("Vorschlag übernehmen") {
                            onSave(proposal.date, proposal.date.hour == nil ? nil : alarmChoice.offsetMinutes)
                            dismiss()
                        }
                        .accessibilityHint("Übernimmt das vorgeschlagene Fälligkeitsdatum.")

                        Button("Vorschlag verwerfen", role: .destructive) {
                            onSave(task.dueDate, task.dueDate?.hour == nil ? nil : task.reminderAlarmOffsetMinutes)
                            dismiss()
                        }
                        .accessibilityHint("Verwirft den Vorschlag und behält ein bereits gesetztes Fälligkeitsdatum bei.")
                    }
                }

                Section {
                    HStack {
                        Button("Heute") { selectedDate = Calendar.current.startOfDay(for: Date()) }
                        Spacer()
                        Button("Morgen") {
                            selectedDate = Calendar.current.date(
                                byAdding: .day, value: 1,
                                to: Calendar.current.startOfDay(for: Date())
                            ) ?? Date()
                        }
                    }
                    .buttonStyle(.borderless)
                }

                if task.dueDate != nil {
                    Section {
                        Button("Datum entfernen", role: .destructive) {
                            onSave(nil, nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Fälligkeitsdatum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        onSave(editedDueDate, includesTime ? alarmChoice.offsetMinutes : nil)
                        dismiss()
                    }
                    .disabled(!isSelectedDateValid)
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct TaskProposalsSheet: View {
    @ObservedObject var session: TaskRecognitionSession
    let parentNoteID: UUID
    let currentPageID: UUID
    let onShowTask: (UUID, CGRect) -> Void
    let drawingForPage: (UUID) -> PKDrawing
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var reminderService: ReminderService
    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingDestination = false
    @State private var selectedTaskIDs = Set<UUID>()
    @State private var expandedTaskIDs = Set<UUID>()
    @StateObject private var auxiliarySessions = AuxiliaryTaskSessions()
    @State private var busyTaskIDs = Set<UUID>()
    @State private var showCurrentPageOnly = false
    @State private var completedIsExpanded = false
    @State private var ignoredIsExpanded = false
    @State private var lastIgnored: NotePageTask?
    @State private var isFinishing = false
    @State private var dateSelection: NotePageTask?

    private var pageIDs: [UUID] {
        store.notes.first(where: { $0.id == parentNoteID })?.pageIDs ?? [currentPageID]
    }

    private var allPageTasks: [NotePageTask] {
        let _ = auxiliarySessions.revision
        return pageIDs.enumerated().flatMap { index, pageID in
            let tasks = pageID == currentPageID
                ? session.tasks
                : auxiliarySessions.session(for: pageID)?.tasks ?? store.recognizedTasks(for: pageID)
            return tasks.map { NotePageTask(pageID: pageID, pageNumber: index + 1, task: $0) }
        }
    }

    private var pageTasks: [NotePageTask] {
        allPageTasks.filter { !showCurrentPageOnly || $0.pageID == currentPageID }
    }

    private var proposals: [NotePageTask] {
        pageTasks.filter { TaskOverviewProjection.category(for: $0.task) == .proposal }
    }

    private var attention: [NotePageTask] {
        pageTasks.filter { TaskOverviewProjection.category(for: $0.task) == .attention }
    }

    private var open: [NotePageTask] {
        pageTasks.filter { TaskOverviewProjection.category(for: $0.task) == .open }
    }

    private var completed: [NotePageTask] {
        pageTasks.filter { TaskOverviewProjection.category(for: $0.task) == .completed }
    }

    private var ignored: [NotePageTask] {
        pageTasks.filter { TaskOverviewProjection.category(for: $0.task) == .ignored }
    }

    private var selectedProposals: [NotePageTask] {
        proposals.filter {
            selectedTaskIDs.contains($0.id)
                && TaskOverviewProjection.mayCreateInBulk(
                    $0.task,
                    isProvisional: $0.pageID == currentPageID && session.isProvisional($0.id)
                )
        }
    }

    private var routingDecision: ReminderRoutingDecision {
        store.reminderRoutingDecision(
            for: parentNoteID,
            taskTitles: allPageTasks.filter { $0.task.isPresent && !$0.task.isIgnored }.map { $0.task.title },
            lists: reminderService.lists,
            globalListID: reminderService.selectedListID
        )
    }

    private var currentList: ReminderList? {
        let listID = routingDecision.targetListID ?? routingDecision.suggestedListID
        return reminderService.lists.first { $0.id == listID }
    }

    var body: some View {
        NavigationStack {
            List {
                if pageIDs.count > 1 {
                    Section {
                        Picker("Seiten", selection: $showCurrentPageOnly) {
                            Text("Alle Seiten").tag(false)
                            Text("Aktuelle Seite").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(.secondary)
                        Text(currentList?.title ?? "Liste auswählen")
                            .lineLimit(1)
                        Spacer()
                        if routingDecision.requiresConfirmation, let currentList {
                            Button("Bestätigen") { confirmDestination(currentList.id) }
                                .font(.subheadline)
                        }
                        Button(routingDecision.requiresConfirmation ? "Ändern" : "Wechseln") {
                            isChoosingDestination = true
                        }
                        .font(.subheadline)
                    }
                    if routingDecision.requiresConfirmation {
                        Text(routingDecision.reason ?? "Bitte bestätige eine Liste für neue Erinnerungen.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: { Text("Ziel für neue Erinnerungen") }

                if session.isAnalyzing || session.errorMessage != nil {
                    Section {
                        HStack(spacing: 8) {
                            if session.isAnalyzing { ProgressView().controlSize(.small) }
                            Text(session.isAnalyzing ? "Handschrift wird erkannt …" : session.errorMessage ?? "")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !session.isAnalyzing {
                                Button("Erneut versuchen") { session.recognizeNow() }
                            }
                        }
                    }
                }

                if let lastIgnored {
                    Section {
                        Button("Ignorieren rückgängig") {
                            taskSession(for: lastIgnored.pageID).restoreIgnoredTask(lastIgnored.id)
                            self.lastIgnored = nil
                        }
                    }
                }

                if proposals.isEmpty && attention.isEmpty && open.isEmpty && completed.isEmpty && ignored.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("Noch keine Aufgaben erkannt", systemImage: "checklist")
                        } description: {
                            Text(showCurrentPageOnly
                                 ? "Auf dieser Seite gibt es keine Aufgaben."
                                 : "Zeichne links ein kleines Quadrat und rechts daneben eine Textzeile.")
                        }
                    }
                } else {
                    if !proposals.isEmpty {
                        Section {
                            ForEach(proposals) { item in taskRow(item, selectable: true) }
                            Button {
                                Task { await createSelected() }
                            } label: {
                                Label("\(selectedProposals.count) Erinnerungen erstellen", systemImage: "plus.circle")
                            }
                            .disabled(selectedProposals.isEmpty || routingDecision.requiresConfirmation || !busyTaskIDs.isEmpty)
                        } header: { Text("Vorschläge") }
                    }
                    if !attention.isEmpty {
                        Section("Handlungsbedarf") {
                            ForEach(attention) { item in taskRow(item) }
                        }
                    }
                    if !open.isEmpty {
                        Section("Offene Erinnerungen") {
                            ForEach(open) { item in taskRow(item) }
                        }
                    }
                    if !completed.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $completedIsExpanded) {
                                ForEach(completed) { item in taskRow(item) }
                            } label: {
                                Text("Erledigt · \(completed.count)")
                            }
                        }
                    }
                    if !ignored.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $ignoredIsExpanded) {
                                ForEach(ignored) { item in taskRow(item) }
                            } label: {
                                Text("Ignoriert · \(ignored.count)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Aufgaben")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        Task { await finishAndDismiss() }
                    }
                    .disabled(!busyTaskIDs.isEmpty || isFinishing)
                }
            }
            .navigationDestination(isPresented: $isChoosingDestination) {
                NoteReminderDestinationView(
                    parentNoteID: parentNoteID,
                    session: session,
                    taskTitles: allPageTasks.filter { $0.task.isPresent && !$0.task.isIgnored }.map { $0.task.title }
                ) {
                    refreshRouting()
                    isChoosingDestination = false
                }
            }
            .sheet(item: $dateSelection) { item in
                TaskDueDateEditorSheet(task: item.task) { dueDate, alarmOffsetMinutes in
                    taskSession(for: item.pageID).updateDueDate(dueDate, for: item.task.id, alarmOffsetMinutes: alarmOffsetMinutes)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { preselectSafeProposals() }
        .onChange(of: isChoosingDestination) { _, isChoosing in
            if isChoosing { session.beginDestinationSelection() }
            else { session.endDestinationSelection() }
        }
        .onDisappear {
            if isChoosingDestination { session.endDestinationSelection() }
            if !isFinishing && !isChoosingDestination {
                Task {
                    for auxiliary in auxiliarySessions.all { await auxiliary.awaitReminderOperations() }
                    auxiliarySessions.deactivate()
                }
            }
        }
        .onChange(of: store.cloudPageRevisions) { _, _ in discardStaleAuxiliarySessions() }
        .onChange(of: auxiliarySessions.revision) { _, _ in discardStaleAuxiliarySessions() }
        .interactiveDismissDisabled(!busyTaskIDs.isEmpty || isFinishing
            || auxiliarySessions.all.contains(where: { $0.isSyncingReminders }))
    }

    private func preselectSafeProposals() {
        selectedTaskIDs.formUnion(proposals.filter {
            $0.task.confidence >= 0.65 && TaskOverviewProjection.mayCreateInBulk(
                $0.task,
                isProvisional: $0.pageID == currentPageID && session.isProvisional($0.task.id)
            )
        }.map(\.id))
    }

    private func confirmDestination(_ listID: String) {
        let titles = allPageTasks.filter { $0.task.isPresent && !$0.task.isIgnored }.map { $0.task.title }
        let context = store.reminderRoutingContext(for: parentNoteID, taskTitles: titles)
        if store.confirmReminderList(listID, for: parentNoteID, context: context) { refreshRouting() }
    }

    private func refreshRouting() {
        session.refreshReminderRouting()
        auxiliarySessions.all.forEach { $0.refreshReminderRouting() }
    }

    private func discardStaleAuxiliarySessions() {
        for pageID in pageIDs where pageID != currentPageID {
            guard let auxiliary = auxiliarySessions.session(for: pageID),
                  auxiliarySessions.cloudRevision(for: pageID) != store.cloudPageRevisions[pageID, default: 0],
                  !auxiliary.isSyncingReminders,
                  !busyTaskIDs.contains(where: { taskID in auxiliary.tasks.contains(where: { $0.id == taskID }) })
            else { continue }
            auxiliarySessions.invalidate(pageID)
        }
    }

    private func taskSession(for pageID: UUID) -> TaskRecognitionSession {
        if pageID == currentPageID { return session }
        if let existing = auxiliarySessions.session(for: pageID),
           auxiliarySessions.cloudRevision(for: pageID) == store.cloudPageRevisions[pageID, default: 0] {
            return existing
        }
        if let existing = auxiliarySessions.session(for: pageID), existing.isSyncingReminders {
            return existing
        }
        auxiliarySessions.invalidate(pageID)
        let auxiliary = TaskRecognitionSession()
        auxiliary.configureReminders(reminderService)
        auxiliary.configure(
            noteID: pageID,
            savedTasks: store.recognizedTasks(for: pageID),
            legacyReferenceDate: store.notes.first(where: { $0.id == parentNoteID })?.createdAt,
            save: { tasks, pageID in store.saveRecognizedTasks(tasks, for: pageID) },
            permitsAutomaticCreation: false
        )
        auxiliary.configureReminderRouting { titles in
            return store.reminderRoutingDecision(
                for: parentNoteID,
                taskTitles: routingTitles(replacingPage: pageID, with: titles),
                lists: reminderService.lists,
                globalListID: reminderService.selectedListID
            )
        }
        auxiliarySessions.install(
            auxiliary,
            for: pageID,
            cloudRevision: store.cloudPageRevisions[pageID, default: 0]
        )
        return auxiliary
    }

    private func routingTitles(replacingPage pageID: UUID, with titles: [String]) -> [String] {
        pageIDs.flatMap { candidateID -> [String] in
            if candidateID == pageID { return titles }
            let tasks = candidateID == currentPageID
                ? session.tasks
                : auxiliarySessions.session(for: candidateID)?.tasks ?? store.recognizedTasks(for: candidateID)
            return tasks.filter { $0.isPresent && !$0.isIgnored }.map(\.title)
        }
    }

    private func createSelected() async {
        guard !routingDecision.requiresConfirmation else { return }
        let items = selectedProposals
        for item in items {
            busyTaskIDs.insert(item.id)
            let pageSession = taskSession(for: item.pageID)
            await pageSession.createReminder(for: item.task.id)
            busyTaskIDs.remove(item.id)
            if pageSession.tasks.first(where: { $0.id == item.id })?.reminderIdentifier != nil {
                selectedTaskIDs.remove(item.id)
            }
        }
    }

    private func finishAndDismiss(show item: NotePageTask? = nil) async {
        guard !isFinishing, busyTaskIDs.isEmpty else { return }
        isFinishing = true
        for auxiliary in auxiliarySessions.all {
            await auxiliary.awaitReminderOperations()
        }
        auxiliarySessions.deactivate()
        dismiss()
        if let item { onShowTask(item.pageID, item.task.bounds) }
    }

    @ViewBuilder
    private func taskRow(_ item: NotePageTask, selectable: Bool = false) -> some View {
        TaskOverviewRow(
            item: item,
            isExpanded: Binding(
                get: { expandedTaskIDs.contains(item.id) },
                set: { if $0 { expandedTaskIDs.insert(item.id) } else { expandedTaskIDs.remove(item.id) } }
            ),
            isSelected: selectedTaskIDs.contains(item.id),
            selectable: selectable && !(item.pageID == currentPageID && session.isProvisional(item.id)),
            isProvisional: item.pageID == currentPageID && session.isProvisional(item.id),
            isBusy: busyTaskIDs.contains(item.id) || (auxiliarySessions.session(for: item.pageID) ?? session).isSyncingReminder(item.id),
            navigationIsDisabled: !busyTaskIDs.isEmpty || isFinishing,
            listTitle: reminderService.lists.first(where: { $0.id == item.task.reminderCalendarIdentifier })?.title,
            handwriting: { handwriting(for: item) },
            toggleSelection: {
                if !selectedTaskIDs.insert(item.id).inserted { selectedTaskIDs.remove(item.id) }
            },
            showInNote: {
                Task { await finishAndDismiss(show: item) }
            },
            updateTitle: { taskSession(for: item.pageID).updateTitle($0, for: item.id) },
            resetTitle: { taskSession(for: item.pageID).resetTitle(for: item.id) },
            editDueDate: { dateSelection = item },
            ignore: {
                taskSession(for: item.pageID).ignoreTask(item.id)
                lastIgnored = item
            },
            restoreIgnored: {
                taskSession(for: item.pageID).restoreIgnoredTask(item.id)
                if lastIgnored?.id == item.id { lastIgnored = nil }
            },
            create: {
                guard !routingDecision.requiresConfirmation else { isChoosingDestination = true; return }
                busyTaskIDs.insert(item.id)
                Task {
                    await taskSession(for: item.pageID).createReminder(for: item.id)
                    busyTaskIDs.remove(item.id)
                }
            },
            restoreReminder: {
                busyTaskIDs.insert(item.id)
                Task {
                    await taskSession(for: item.pageID).restoreReminder(for: item.id)
                    busyTaskIDs.remove(item.id)
                }
            },
            retry: { taskSession(for: item.pageID).retryReminderSync(for: item.id) }
        )
    }

    private func handwriting(for item: NotePageTask) -> UIImage? {
        let drawing = drawingForPage(item.pageID)
        let box = item.task.bounds
        let neighbors = allPageTasks
            .filter { $0.pageID == item.pageID && $0.task.isPresent && $0.id != item.id }
            .map { $0.task.bounds.midY }
        let halfHeight = max(48, min(76, box.height * 1.25))
        var top = box.midY - halfHeight
        var bottom = box.midY + halfHeight
        if let previous = neighbors.filter({ $0 < box.midY }).max() {
            top = max(top, (previous + box.midY) / 2 + 1)
        }
        if let next = neighbors.filter({ $0 > box.midY }).min() {
            bottom = min(bottom, (next + box.midY) / 2 - 1)
        }
        let rect = CGRect(
            x: max(0, box.minX - 8),
            y: max(0, top),
            width: max(0, NoteStore.pageSize.width - max(0, box.minX - 8) - 8),
            height: max(0, min(NoteStore.pageSize.height, bottom) - max(0, top))
        )
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        return drawing.image(from: rect, scale: 1.5)
    }
}

private struct NotePageTask: Identifiable {
    let pageID: UUID
    let pageNumber: Int
    let task: RecognizedTask
    var id: UUID { task.id }
}

@MainActor
private final class AuxiliaryTaskSessions: ObservableObject {
    @Published private(set) var revision = 0
    private var sessions: [UUID: TaskRecognitionSession] = [:]
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var cloudRevisions: [UUID: Int] = [:]

    var all: [TaskRecognitionSession] { Array(sessions.values) }

    func session(for pageID: UUID) -> TaskRecognitionSession? { sessions[pageID] }
    func cloudRevision(for pageID: UUID) -> Int? { cloudRevisions[pageID] }

    func install(_ session: TaskRecognitionSession, for pageID: UUID, cloudRevision: Int) {
        sessions[pageID] = session
        cloudRevisions[pageID] = cloudRevision
        subscriptions[pageID] = session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.revision += 1 }
        }
        revision += 1
    }

    func invalidate(_ pageID: UUID) {
        sessions.removeValue(forKey: pageID)?.deactivate()
        subscriptions.removeValue(forKey: pageID)
        cloudRevisions.removeValue(forKey: pageID)
        revision += 1
    }

    func deactivate() {
        sessions.values.forEach { $0.deactivate() }
        sessions.removeAll()
        subscriptions.removeAll()
        cloudRevisions.removeAll()
        revision += 1
    }
}

private struct TaskOverviewRow: View {
    let item: NotePageTask
    @Binding var isExpanded: Bool
    let isSelected: Bool
    let selectable: Bool
    let isProvisional: Bool
    let isBusy: Bool
    let navigationIsDisabled: Bool
    let listTitle: String?
    let handwriting: () -> UIImage?
    let toggleSelection: () -> Void
    let showInNote: () -> Void
    let updateTitle: (String) -> Void
    let resetTitle: () -> Void
    let editDueDate: () -> Void
    let ignore: () -> Void
    let restoreIgnored: () -> Void
    let create: () -> Void
    let restoreReminder: () -> Void
    let retry: () -> Void
    @State private var title = ""

    private var task: RecognizedTask { item.task }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if isExpanded, let crop = handwriting() {
                    Image(uiImage: crop)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 140)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Handschriftausschnitt")
                }
                Button("In Notiz zeigen", systemImage: "scope", action: showInNote)
                    .disabled(navigationIsDisabled)
                if task.reminderIdentifier == nil && !task.isIgnored {
                    TextField("Aufgabentitel", text: $title)
                        .onSubmit { updateTitle(title) }
                        .onChange(of: title) { _, newValue in updateTitle(newValue) }
                        .accessibilityLabel("Titel der erkannten Aufgabe")
                        .disabled(isBusy)
                    if task.correctedText != nil {
                        Button("Erkennung verwenden") {
                            title = task.recognizedText
                            resetTitle()
                        }
                        .disabled(isBusy)
                    }
                }
                if let proposal = task.dueDateProposal {
                    Button("Datum prüfen: \(TaskDueDateAnnotationLayout.fullDate(proposal.date))", action: editDueDate)
                        .disabled(isProvisional || task.isIgnored || isBusy)
                        .accessibilityHint("Prüft den erkannten Datumstext und lässt den Vorschlag übernehmen oder verwerfen.")
                }
                Button(task.dueDate == nil ? "Datum hinzufügen" : "Fälligkeitsdatum ändern", action: editDueDate)
                    .disabled(isProvisional || task.isIgnored || isBusy)
                if task.isIgnored {
                    Button("Wiederherstellen", action: restoreIgnored)
                        .disabled(isBusy)
                } else if task.reminderIdentifier == nil {
                    Button("Erinnerung erstellen", systemImage: "plus.circle", action: create)
                        .disabled(isProvisional || isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Vorschlag ignorieren", systemImage: "eye.slash", action: ignore)
                        .disabled(isBusy)
                } else if task.markerState == .deleted && task.isPresent && !task.wasRemovedFromDrawing {
                    Button("Erinnerung wiederherstellen", systemImage: "arrow.counterclockwise.circle", action: restoreReminder)
                        .disabled(isBusy)
                }
                if let error = task.reminderSyncError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    Button("Für diese Aufgabe erneut versuchen", action: retry)
                        .disabled(isBusy)
                }
                if task.reminderIdentifier != nil {
                    Text(detailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 8)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if selectable {
                    Button(action: toggleSelection) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isSelected ? "Auswahl aufheben" : "Zum Erstellen auswählen")
                } else {
                    TaskStatusMarker(state: task.markerState)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text("Seite \(item.pageNumber)")
                        if let dueDate = task.dueDate {
                            Text("· \(TaskDueDateAnnotationLayout.shortDate(dueDate))")
                        }
                        if let proposal = task.dueDateProposal {
                            Label("Datum prüfen · \(TaskDueDateAnnotationLayout.shortDate(proposal.date))", systemImage: "calendar.badge.exclamationmark")
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Datumsvorschlag prüfen: \(TaskDueDateAnnotationLayout.fullDate(proposal.date))")
                        }
                        if task.reminderIdentifier != nil {
                            Text("· \(listTitle ?? "Ursprüngliche Liste nicht verfügbar")")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if isProvisional || (task.reminderIdentifier == nil && task.confidence < 0.65) {
                        Label(isProvisional ? "Erkennung läuft" : "Erkennung prüfen", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if task.reminderSyncError != nil || task.reminderRemovalPending {
                        Label(task.reminderSyncError != nil ? "Synchronisierung fehlgeschlagen" : "Änderung wird synchronisiert", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .onAppear { title = task.title }
        .onChange(of: task.title) { _, newValue in title = newValue }
    }

    private var detailText: String {
        if task.wasRemovedFromDrawing {
            return task.reminderRemovalPending
                ? "Das Kästchen wurde entfernt. Die verknüpfte Erinnerung wird entfernt."
                : "Das Kästchen wurde entfernt."
        }
        if !task.isPresent {
            return "Das Kästchen wurde gerade nicht erkannt. Prüfe die Handschrift in der Notiz."
        }
        switch task.markerState {
        case .open: return "Verknüpfte Erinnerung ist offen. Änderungen am Titel werden nicht übertragen."
        case .completed: return "Verknüpfte Erinnerung ist erledigt."
        case .deleted: return "Die verknüpfte Erinnerung wurde in Erinnerungen gelöscht."
        case .proposal: return "Noch keine Erinnerung erstellt."
        }
    }
}

private struct NoteReminderDestinationView: View {
    let parentNoteID: UUID
    @ObservedObject var session: TaskRecognitionSession
    let taskTitles: [String]
    let didConfirm: () -> Void

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var reminderService: ReminderService
    @State private var selectedListID = ""
    @State private var setCustomerDefault = false

    private var note: Note? { store.notes.first { $0.id == parentNoteID } }
    private var customer: Customer? { store.customer(for: note?.customerID) }
    private var preferredIDs: Set<String> {
        Set((customer?.reminderListIDs ?? []) + [customer?.defaultReminderListID].compactMap { $0 })
    }
    private var preferredLists: [ReminderList] {
        reminderService.lists.filter { preferredIDs.contains($0.id) }
    }
    private var otherLists: [ReminderList] {
        reminderService.lists.filter { !preferredIDs.contains($0.id) }
    }
    private var selectedListIsAvailable: Bool {
        reminderService.hasAccess && reminderService.lists.contains { $0.id == selectedListID }
    }

    var body: some View {
        List {
            if let reason = session.routingDecision?.reason {
                Section {
                    Label(reason, systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                }
            }

            if !reminderService.hasAccess {
                Section {
                    Text("Erlaube den Zugriff auf Erinnerungen, um eine Liste auszuwählen.")
                    Button("Zugriff erlauben") {
                        Task { await reminderService.requestAccess() }
                    }
                    .disabled(reminderService.isRequestingAccess)
                }
            } else {
                if !preferredLists.isEmpty {
                    Section("Listen dieses Kunden") {
                        ForEach(preferredLists) { list in listRow(list) }
                    }
                }

                if !otherLists.isEmpty || preferredLists.isEmpty {
                    Section(preferredLists.isEmpty ? "Alle Listen" : "Andere Listen") {
                        ForEach(otherLists) { list in listRow(list) }
                        if reminderService.lists.isEmpty {
                            Text("Keine beschreibbaren Erinnerungslisten verfügbar.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if customer != nil {
                    Section {
                        Toggle("Auch als Standard für diesen Kunden", isOn: $setCustomerDefault)
                    } footer: {
                        Text("Künftige Notizen dieses Kunden verwenden diese Liste als Ausgangspunkt. Weitere zugehörige Listen bleiben erhalten.")
                    }
                }

                Section {
                    Button("Liste für diese Notiz bestätigen") { confirmSelection() }
                        .disabled(!selectedListIsAvailable)
                } footer: {
                    Text("Die App merkt sich deine bestätigte Wahl lokal und schlägt bei ähnlichen Notizen mit der Zeit passendere Listen vor. Bestehende Erinnerungen werden nicht verschoben.")
                }
            }

            if let error = store.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Erinnerungsliste")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: preselectList)
    }

    private func listRow(_ list: ReminderList) -> some View {
        Button {
            selectedListID = list.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(list.title)
                        .foregroundStyle(.primary)
                    Text(list.sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if list.id == customer?.defaultReminderListID {
                    Text("Standard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if list.id == selectedListID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityAddTraits(list.id == selectedListID ? .isSelected : [])
    }

    private func preselectList() {
        guard selectedListID.isEmpty else { return }
        for candidate in [session.routingDecision?.suggestedListID,
                          session.routingDecision?.targetListID,
                          customer?.defaultReminderListID,
                          reminderService.selectedListID].compactMap({ $0 }) {
            if reminderService.lists.contains(where: { $0.id == candidate }) {
                selectedListID = candidate
                return
            }
        }
    }

    private func confirmSelection() {
        guard selectedListIsAvailable else { return }
        let context = store.reminderRoutingContext(for: parentNoteID, taskTitles: taskTitles)
        guard store.confirmReminderList(
            selectedListID,
            for: parentNoteID,
            context: context,
            setCustomerDefault: setCustomerDefault
        ) else { return }
        session.refreshReminderRouting()
        didConfirm()
    }
}

private struct TaskProposalRow: View {
    let task: RecognizedTask
    let isProvisional: Bool
    let isSyncingReminders: Bool
    let requiresDestination: Bool
    let chooseDestination: () -> Void
    let updateTitle: (String) -> Void
    let resetTitle: () -> Void
    let editDueDate: () -> Void
    let createReminder: () async -> Void
    let restoreReminder: () async -> Void
    @State private var title: String
    @FocusState private var titleIsFocused: Bool

    init(
        task: RecognizedTask,
        isProvisional: Bool,
        isSyncingReminders: Bool,
        requiresDestination: Bool,
        chooseDestination: @escaping () -> Void,
        updateTitle: @escaping (String) -> Void,
        resetTitle: @escaping () -> Void,
        editDueDate: @escaping () -> Void,
        createReminder: @escaping () async -> Void,
        restoreReminder: @escaping () async -> Void
    ) {
        self.task = task
        self.isProvisional = isProvisional
        self.isSyncingReminders = isSyncingReminders
        self.requiresDestination = requiresDestination
        self.chooseDestination = chooseDestination
        self.updateTitle = updateTitle
        self.resetTitle = resetTitle
        self.editDueDate = editDueDate
        self.createReminder = createReminder
        self.restoreReminder = restoreReminder
        _title = State(initialValue: task.title)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TaskStatusMarker(state: task.markerState)
                .padding(.top, 2)
                .accessibilityHidden(task.reminderIdentifier != nil)

            VStack(alignment: .leading, spacing: 6) {
                if task.reminderIdentifier == nil {
                    TextField("Aufgabentitel", text: $title)
                        .focused($titleIsFocused)
                        .onSubmit { updateTitle(title) }
                        .onChange(of: title) { _, newValue in updateTitle(newValue) }
                        .onChange(of: task.title) { _, newValue in
                            if !titleIsFocused { title = newValue }
                        }
                        .accessibilityLabel("Titel der erkannten Aufgabe")
                } else {
                    Text(task.title)
                    Label(reminderStatusText, systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(task.markerState == .deleted ? Color.red : Color.secondary)
                }

                Label(
                    isProvisional ? "Erkennung wird ergänzt" :
                        (task.confidence < 0.65 ? "Handschrift unsicher erkannt" : "Handschrift erkannt"),
                    systemImage: isProvisional || task.confidence < 0.65
                        ? "exclamationmark.circle" : "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(isProvisional || task.confidence < 0.65 ? Color.orange : Color.secondary)

                Button(action: editDueDate) {
                    if let proposal = task.dueDateProposal {
                        Text("Datum prüfen: \(TaskDueDateAnnotationLayout.fullDate(proposal.date))")
                    } else if let dueDate = task.dueDate {
                        Text("Fällig: \(TaskDueDateAnnotationLayout.fullDate(dueDate))")
                    } else {
                        Text("Datum hinzufügen")
                    }
                }
                .font(.subheadline)
                .disabled(isProvisional)
                .accessibilityLabel(task.dueDateProposal == nil
                    ? (task.dueDate == nil ? "Fälligkeitsdatum hinzufügen" : "Fälligkeitsdatum ändern")
                    : "Datumsvorschlag prüfen")
                .accessibilityValue(task.dueDateProposal.map { TaskDueDateAnnotationLayout.fullDate($0.date) }
                    ?? task.dueDate.map { TaskDueDateAnnotationLayout.fullDate($0) }
                    ?? "Kein Datum")
                .accessibilityHint(task.dueDateProposal == nil ? "Öffnet die Datumsauswahl." : "Öffnet den Datumsvorschlag zum Prüfen.")

                if task.reminderIdentifier == nil, task.correctedText != nil {
                    Button("Erkennung verwenden") {
                        title = task.recognizedText
                        resetTitle()
                    }
                    .font(.caption)
                    .accessibilityLabel("Korrektur zurücksetzen")
                }

                if task.reminderIdentifier == nil {
                    Button {
                        if requiresDestination { chooseDestination() }
                        else { Task { await createReminder() } }
                    } label: {
                        if isSyncingReminders {
                            ProgressView()
                        } else {
                            Label(
                                requiresDestination ? "Liste auswählen" : "Erinnerung erstellen",
                                systemImage: requiresDestination ? "list.bullet" : "plus.circle"
                            )
                        }
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSyncingReminders
                            || (isProvisional && !requiresDestination)
                    )
                }

                if task.markerState == .deleted {
                    Button {
                        Task { await restoreReminder() }
                    } label: {
                        if isSyncingReminders {
                            ProgressView()
                        } else {
                            Label("Erinnerung wiederherstellen", systemImage: "arrow.counterclockwise.circle")
                        }
                    }
                    .disabled(isSyncingReminders)
                }

                if let reminderSyncError = task.reminderSyncError {
                    Text(reminderSyncError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
        .buttonStyle(.borderless)
    }

    private var reminderStatusText: String {
        switch task.markerState {
        case .proposal:
            return "Noch keine Erinnerung erstellt"
        case .open:
            return "Erinnerung offen · Titel wird nicht synchronisiert"
        case .completed:
            return "Erinnerung erledigt · Titel wird nicht synchronisiert"
        case .deleted:
            return "In Erinnerungen gelöscht"
        }
    }
}

private struct MissingLinkedTaskRow: View {
    let task: RecognizedTask
    let isSyncingReminders: Bool
    let restoreReminder: () async -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TaskStatusMarker(state: task.markerState)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                Label(statusText, systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(task.markerState == .deleted ? Color.red : Color.secondary)

                if task.markerState == .deleted {
                    Button {
                        Task { await restoreReminder() }
                    } label: {
                        if isSyncingReminders {
                            ProgressView()
                        } else {
                            Label("Erinnerung wiederherstellen", systemImage: "arrow.counterclockwise.circle")
                        }
                    }
                    .disabled(isSyncingReminders)
                }

                if let reminderSyncError = task.reminderSyncError {
                    Text(reminderSyncError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch task.markerState {
        case .proposal:
            return "Noch keine Erinnerung erstellt"
        case .open:
            return "Erinnerung offen"
        case .completed:
            return "Erinnerung erledigt"
        case .deleted:
            return "In Erinnerungen gelöscht"
        }
    }
}

private final class NoteCanvasView: PKCanvasView {
    private let canvasUndoManager = UndoManager()
    var didMoveToWindowHandler: (() -> Void)?

    override var undoManager: UndoManager? {
        canvasUndoManager
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        didMoveToWindowHandler?()
    }
}

private extension Color {
    static let editorBackground = Color(
        red: 235.0 / 255.0,
        green: 232.0 / 255.0,
        blue: 226.0 / 255.0
    )
}
