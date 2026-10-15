import Combine
import Foundation
import PencilKit

@MainActor
final class TaskRecognitionSession: ObservableObject {
    @Published private(set) var tasks: [RecognizedTask] = []
    @Published private(set) var isAnalyzing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var reminderErrorMessage: String?
    @Published private(set) var isSyncingReminders = false
    @Published private(set) var reminderOperationRevision = 0
    @Published private(set) var routingDecision: ReminderRoutingDecision?

    private let debounceDuration: Duration
    private let autoCreationDelay: Duration
    private let recognize: @Sendable (Data) async throws -> [TaskCandidate]
    private var noteID: UUID?
    private var generation = 0
    private var sessionEpoch = 0
    private var debounceTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var recognitionToken: UUID?
    private var activeRecognition: (data: Data, revision: Int)?
    private var pendingRecognition: (data: Data, revision: Int)?
    private var deferredRecognition: (candidates: [TaskCandidate], data: Data, revision: Int)?
    private var committedRevision = -1
    private var provisionalTaskIDs = Set<UUID>()
    private var finishDrainCount = 0
    private var saveTasks: (([RecognizedTask], UUID) -> Void)?
    private var latestDrawingData: Data?
    private var reminderService: ReminderService?
    private var resolveReminderRouting: (([String]) -> ReminderRoutingDecision)?
    private var reminderSessionGeneration = 0
    private var reminderSyncTask: Task<Void, Never>?
    private var reminderSyncNeedsAnotherPass = false
    private var reminderStatusTask: Task<Void, Never>?
    private var reminderStatusToken: UUID?
    private var reminderStatusNeedsRefresh = false
    private var reminderStateRevision = 0
    private var automaticCreationTask: Task<Void, Never>?
    private var automaticCreationToken: UUID?
    private var automaticCreationSuppressionCount = 0
    private var isDestinationSelectionActive = false
    private var isDrawingActive = false
    private var creatingTaskIDs = Set<UUID>()
    private var reminderOperationIDs = Set<UUID>()
    private var perTaskReminderOperations = [UUID: Set<UUID>]()
    private var removalTasks: [UUID: Task<Void, Never>] = [:]
    private var syncingTaskIDs = Set<UUID>()
    private var scheduledReminderOperations = 0
    private var reminderIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var permitsAutomaticCreation = true
    private var legacyReferenceDate: TaskDueDate?
    private var newTaskReferenceIsTrusted = true
    private var didBeginDrawingActivity = false
    private var initialDrawingInkBounds: [CGRect]?

    init(
        debounceDuration: Duration = .milliseconds(750),
        autoCreationDelay: Duration = .seconds(2),
        recognize: (@Sendable (Data) async throws -> [TaskCandidate])? = nil
    ) {
        self.debounceDuration = debounceDuration
        self.autoCreationDelay = autoCreationDelay
        if let recognize {
            self.recognize = recognize
        } else {
            let engine = TaskRecognitionEngine()
            self.recognize = { drawingData in
                try await engine.recognize(drawingData: drawingData)
            }
        }
    }

    func configure(
        noteID: UUID,
        savedTasks: [RecognizedTask],
        legacyReferenceDate: Date? = nil,
        save: @escaping ([RecognizedTask], UUID) -> Void,
        permitsAutomaticCreation: Bool = true
    ) {
        guard self.noteID != noteID else { return }
        deactivate()
        self.noteID = noteID
        self.permitsAutomaticCreation = permitsAutomaticCreation
        self.legacyReferenceDate = legacyReferenceDate.map(TaskDueDate.init(date:))
        // An old note may receive its first OCR pass long after the writing was
        // done. Its creation day is useful context, but cannot prove "tomorrow".
        newTaskReferenceIsTrusted = legacyReferenceDate == nil
        didBeginDrawingActivity = false
        initialDrawingInkBounds = nil
        tasks = savedTasks
        // Persisted tasks are authoritative until this page supplies a newer
        // drawing snapshot. Routing and manual corrections must work at reopen.
        committedRevision = generation
        saveTasks = save
        reminderStateRevision += 1
        resumeReminderLifecycle()
        Task { [weak self] in
            await self?.refreshReminderStatuses()
        }
    }

    func configureReminders(_ service: ReminderService) {
        reminderService = service
        resumeReminderLifecycle()
    }

    /// Seeds legacy linked tasks from the saved drawing before a quick erase can
    /// overtake the first OCR pass. This only reads local geometry and never
    /// starts recognition or Reminder operations.
    func seedRemovalEvidence(from drawingData: Data) {
        guard noteID != nil,
              let drawing = try? PKDrawing(data: drawingData) else { return }
        let sampled = TaskRecognitionEngine.sampleVisibleGeometry(from: drawing)
        initialDrawingInkBounds = sampled.compactMap { stroke in
            guard let first = stroke.points.first else { return nil }
            let xs = stroke.points.map(\.x)
            let ys = stroke.points.map(\.y)
            return CGRect(
                x: xs.min() ?? first.x, y: ys.min() ?? first.y,
                width: (xs.max() ?? first.x) - (xs.min() ?? first.x),
                height: (ys.max() ?? first.y) - (ys.min() ?? first.y)
            ).insetBy(dx: -0.5, dy: -0.5)
        }
        let detections = CheckboxDetector.detect(
            strokes: sampled,
            pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800),
            limit: 31
        )
        for index in tasks.indices
        where !tasks[index].wasRemovedFromDrawing
            && (tasks[index].checkboxInkEvidence == nil
                || tasks[index].checkboxStrokeEvidence == nil) {
            let taskBounds = tasks[index].bounds
            guard let detection = detections.first(where: { detection in
                let intersection = detection.bounds.intersection(taskBounds)
                let smallerArea = min(
                    detection.bounds.width * detection.bounds.height,
                    taskBounds.width * taskBounds.height
                )
                guard !intersection.isNull, smallerArea > 0 else { return false }
                let overlap = intersection.width * intersection.height / smallerArea
                let distance = hypot(
                    detection.bounds.midX - taskBounds.midX,
                    detection.bounds.midY - taskBounds.midY
                )
                return overlap >= 0.32
                    && distance <= 0.38 * max(36, max(taskBounds.width, taskBounds.height))
            }) else { continue }
            let samples = CheckboxRemovalEvidence.samples(in: sampled, near: taskBounds)
            guard samples.count >= 12 else { continue }
            if tasks[index].checkboxInkEvidence == nil {
                tasks[index].checkboxInkEvidence = samples
            }
            if tasks[index].checkboxStrokeEvidence == nil {
                tasks[index].checkboxStrokeEvidence = CheckboxRemovalEvidence.strokeEvidence(
                    in: drawing, sampled: sampled, near: detection.bounds
                )
            }
        }
    }

    func configureReminderRouting(
        _ resolve: @escaping ([String]) -> ReminderRoutingDecision
    ) {
        resolveReminderRouting = resolve
        refreshReminderRouting()
    }

    func refreshReminderRouting() {
        cancelAutomaticCreation()
        guard recognitionIsStable else { return }
        routingDecision = resolveReminderRouting?(presentTaskTitles)
        scheduleAutomaticCreation()
    }

    func beginDestinationSelection() {
        isDestinationSelectionActive = true
        cancelAutomaticCreation()
    }

    func endDestinationSelection() {
        isDestinationSelectionActive = false
        refreshReminderRouting()
    }

    func drawingDidChange(_ drawingData: Data, automatically: Bool = true) {
        guard noteID != nil else { return }
        if latestDrawingData == drawingData,
           (pendingRecognition?.data == drawingData
                || (pendingRecognition == nil &&
                    (committedRevision == generation
                        || activeRecognition?.data == drawingData))) {
            if !automatically, pendingRecognition != nil {
                debounceTask?.cancel()
                debounceTask = nil
                startRecognitionIfPossible()
            }
            return
        }
        cancelAutomaticCreation()
        latestDrawingData = drawingData
        generation += 1
        pendingRecognition = (drawingData, generation)
        errorMessage = nil
        if !automatically || finishDrainCount > 0 {
            debounceTask?.cancel()
            debounceTask = nil
            startRecognitionIfPossible()
        } else {
            scheduleRecognitionIfNeeded()
        }
    }

    func drawingActivityBegan() {
        cancelAutomaticCreation()
        isDrawingActive = true
        didBeginDrawingActivity = true
    }

    func drawingActivityEnded(_ drawingData: Data) {
        isDrawingActive = false
        if let deferredRecognition,
           deferredRecognition.revision == generation,
           deferredRecognition.data == drawingData,
           pendingRecognition == nil,
           recognitionTask == nil {
            self.deferredRecognition = nil
            latestDrawingData = drawingData
            applyFinal(deferredRecognition.candidates, data: drawingData, revision: generation)
            runStableSideEffects()
            return
        }
        // The last PencilKit delegate callback may arrive after tool-up. Queue a
        // committed snapshot even when the serialized bytes did not change.
        drawingDidChange(drawingData)
        if let deferredRecognition {
            self.deferredRecognition = nil
            let epoch = sessionEpoch
            let revision = generation
            Task { [weak self] in
                let unchanged = await TaskRecognitionSnapshot.unchangedCandidates(
                    deferredRecognition.candidates,
                    from: deferredRecognition.data,
                    to: drawingData
                )
                guard let self, self.sessionEpoch == epoch else { return }
                if self.generation == revision, !self.isDrawingActive,
                   self.committedRevision != revision {
                    self.applyProvisional(unchanged)
                } else if self.isDrawingActive {
                    self.retainDeferred(deferredRecognition)
                }
            }
        }
        if pendingRecognition == nil, committedRevision != generation,
           activeRecognition?.revision != generation {
            pendingRecognition = (drawingData, generation)
            scheduleRecognitionIfNeeded()
        }
        scheduleAutomaticCreation()
    }

    func recognizeNow() {
        guard let latestDrawingData else { return }
        cancelAutomaticCreation()
        generation += 1
        pendingRecognition = (latestDrawingData, generation)
        debounceTask?.cancel()
        debounceTask = nil
        startRecognitionIfPossible()
    }

    func isProvisional(_ taskID: UUID) -> Bool {
        provisionalTaskIDs.contains(taskID)
    }

    func isSyncingReminder(_ taskID: UUID) -> Bool {
        !(perTaskReminderOperations[taskID]?.isEmpty ?? true)
            || creatingTaskIDs.contains(taskID)
            || removalTasks[taskID] != nil
            || syncingTaskIDs.contains(taskID)
    }

    func ignoreTask(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isIgnored = true
        cancelAutomaticCreation()
        persist()
        refreshReminderRouting()
    }

    func restoreIgnoredTask(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isIgnored = false
        persist()
        refreshReminderRouting()
    }

    func retryReminderSync(for taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].reminderSyncError = nil
        persist()
        if tasks[index].reminderRemovalPending {
            startReminderRemoval(for: taskID)
        } else if tasks[index].reminderRestorePending,
                  tasks[index].isPresent,
                  tasks[index].reminderStatus == .deleted {
            scheduleReminderOperation { [weak self] in await self?.restoreReminder(for: taskID) }
        } else if tasks[index].reminderIdentifier == nil {
            scheduleReminderOperation { [weak self] in await self?.createReminder(for: taskID) }
        } else {
            startReminderSync(includePreviousErrors: false)
        }
    }

    func updateTitle(_ title: String, for taskID: UUID) {
        cancelAutomaticCreation()
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].correctedText = title == tasks[index].recognizedText
            ? nil
            : title
        // This callback can run for every keystroke. Surface a suggestion while
        // typing; only a committed OCR snapshot may automatically sync a date.
        inspectEditedTitle(at: index)
        persist()
        refreshReminderRouting()
    }

    func resetTitle(for taskID: UUID) {
        cancelAutomaticCreation()
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].correctedText = nil
        inspectEditedTitle(at: index)
        persist()
        refreshReminderRouting()
    }

    func updateDueDate(_ dueDate: TaskDueDate?, for taskID: UUID) {
        let alarmOffsetMinutes = tasks.first(where: { $0.id == taskID })?.reminderAlarmOffsetMinutes
        updateDueDate(dueDate, for: taskID, alarmOffsetMinutes: alarmOffsetMinutes)
    }

    func updateDueDate(_ dueDate: TaskDueDate?, for taskID: UUID, alarmOffsetMinutes: Int?) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              !provisionalTaskIDs.contains(taskID) else { return }
        let resolvedAlarm = dueDate?.hasTime == true ? alarmOffsetMinutes : nil
        let dateChanged = tasks[index].dueDate != dueDate
        let alarmChanged = tasks[index].reminderAlarmOffsetMinutes != resolvedAlarm
        let ownershipChanged = tasks[index].dueDateSource != .manual
            || tasks[index].dueDateProposal != nil
        guard dateChanged || alarmChanged || ownershipChanged else { return }
        tasks[index].dueDate = dueDate
        tasks[index].reminderAlarmOffsetMinutes = resolvedAlarm
        tasks[index].dueDateSource = .manual
        tasks[index].dueDateProposal = nil
        if tasks[index].reminderIdentifier != nil {
            if dateChanged { tasks[index].reminderDueDateSyncPending = true }
            if alarmChanged || (dateChanged && resolvedAlarm != nil) {
                tasks[index].alarmSyncPending = true
            }
        }
        reminderStateRevision += 1
        persist()
        if dateChanged || alarmChanged { startReminderSync(includePreviousErrors: false) }
    }

    func createReminder(for taskID: UUID) async {
        guard let reminderService,
              let configuredNoteID = noteID,
              let task = tasks.first(where: { $0.id == taskID }),
              !provisionalTaskIDs.contains(taskID),
              task.reminderIdentifier == nil,
              task.isPresent, !task.isIgnored, !task.wasRemovedFromDrawing,
              !creatingTaskIDs.contains(taskID),
              !isDestinationSelectionActive else { return }

        // Re-evaluate at the moment of creation. A note title, customer setting,
        // or another task's correction may have changed since recognition.
        let decision = resolveReminderRouting?(presentTaskTitles)
        if routingDecision != decision {
            routingDecision = decision
        }
        guard decision?.requiresConfirmation != true else { return }
        let targetListID = decision?.targetListID
        guard resolveReminderRouting == nil || targetListID != nil else { return }
        let effectiveListID = targetListID ?? reminderService.selectedListID

        let sessionGeneration = reminderSessionGeneration
        creatingTaskIDs.insert(taskID)
        setTaskSyncError(nil, for: taskID)
        reminderErrorMessage = nil
        let operationID = beginReminderOperation(for: taskID)
        defer {
            creatingTaskIDs.remove(taskID)
            endReminderOperation(operationID, for: taskID)
        }

        do {
            let identifier = try await reminderService.createReminder(
                title: task.title,
                isCompleted: task.isChecked,
                taskID: task.id,
                dueDate: task.dueDate,
                alarmOffsetMinutes: task.reminderAlarmOffsetMinutes,
                preferredListIdentifier: targetListID
            )
            guard reminderSessionGeneration == sessionGeneration,
                  noteID == configuredNoteID,
                  let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            // The title and completion approved at tap time are what EventKit
            // received. Keep that title stable and let a later pass propagate a
            // checkbox edit made while creation was in flight.
            tasks[index].recognizedText = task.recognizedText
            tasks[index].correctedText = task.correctedText
            tasks[index].reminderIdentifier = identifier
            tasks[index].reminderCalendarIdentifier = effectiveListID
            tasks[index].reminderStatus = task.isChecked ? .completed : .open
            tasks[index].reminderLastSyncedIsChecked = task.isChecked
            // A recovered marker may point to an older reminder with a different date.
            tasks[index].reminderDueDateSyncPending = task.dueDateSource != nil
                || tasks[index].dueDate != task.dueDate
            tasks[index].alarmSyncPending = task.reminderAlarmOffsetMinutes != nil
                || tasks[index].reminderAlarmOffsetMinutes != task.reminderAlarmOffsetMinutes
            tasks[index].reminderSyncError = nil
            if tasks[index].wasRemovedFromDrawing {
                tasks[index].reminderRemovalPending = true
                tasks[index].reminderRestorePending = true
            }
            reminderStateRevision += 1
            persist()
            resumeReminderLifecycle()
            startReminderSync(includePreviousErrors: false)
            await refreshReminderStatuses()
        } catch is CancellationError {
            return
        } catch {
            guard reminderSessionGeneration == sessionGeneration,
                  noteID == configuredNoteID else { return }
            let message = Self.reminderMessage(for: error)
            setTaskSyncError(message, for: taskID)
            reminderErrorMessage = message
            persist()
        }
    }

    func restoreReminder(for taskID: UUID) async {
        guard let reminderService,
              let configuredNoteID = noteID,
              let task = tasks.first(where: { $0.id == taskID }),
              let deletedIdentifier = task.reminderIdentifier,
              task.reminderStatus == .deleted,
              task.isPresent, !task.wasRemovedFromDrawing,
              !creatingTaskIDs.contains(taskID) else { return }

        let sessionGeneration = reminderSessionGeneration
        creatingTaskIDs.insert(taskID)
        setTaskSyncError(nil, for: taskID)
        reminderErrorMessage = nil
        let operationID = beginReminderOperation(for: taskID)
        defer {
            creatingTaskIDs.remove(taskID)
            endReminderOperation(operationID, for: taskID)
        }

        do {
            let request = ReminderLookupRequest(
                taskIdentifier: task.id,
                reminderIdentifier: deletedIdentifier,
                calendarIdentifier: task.reminderCalendarIdentifier
            )
            let snapshot = try await reminderService.fetchReminderRecords(for: [request])
            guard reminderSessionGeneration == sessionGeneration,
                  noteID == configuredNoteID,
                  let currentIndex = tasks.firstIndex(where: { $0.id == taskID }),
                  tasks[currentIndex].reminderIdentifier == deletedIdentifier,
                  tasks[currentIndex].reminderStatus == .deleted,
                  tasks[currentIndex].isPresent,
                  !tasks[currentIndex].wasRemovedFromDrawing else { return }

            if let record = snapshot.recordsByTaskIdentifier[taskID] {
                applyRestoredReminder(record, toTaskAt: currentIndex)
                return
            }

            if let originalListIdentifier = task.reminderCalendarIdentifier,
               !snapshot.readableCalendarIdentifiers.contains(originalListIdentifier) {
                throw ReminderServiceError.originalListUnavailable
            }

            // EventKitReminderStore performs the marker lookup once more inside
            // createReminder. That closes the gap between this live status check
            // and the save, while the task-level lock coalesces repeated taps.
            let identifier = try await reminderService.createReminder(
                title: task.title,
                isCompleted: task.isChecked,
                taskID: task.id,
                dueDate: task.dueDate,
                alarmOffsetMinutes: task.reminderAlarmOffsetMinutes,
                preferredListIdentifier: task.reminderCalendarIdentifier
            )
            guard reminderSessionGeneration == sessionGeneration,
                  noteID == configuredNoteID,
                  let index = tasks.firstIndex(where: {
                      $0.id == taskID
                          && (($0.reminderIdentifier == deletedIdentifier
                                  && $0.reminderStatus == .deleted)
                              || $0.reminderRestorePending)
                  }) else { return }

            tasks[index].reminderIdentifier = identifier
            tasks[index].reminderCalendarIdentifier = task.reminderCalendarIdentifier
            tasks[index].reminderStatus = task.isChecked ? .completed : .open
            tasks[index].reminderLastSyncedIsChecked = task.isChecked
            tasks[index].reminderDueDateSyncPending = task.dueDateSource != nil
                || tasks[index].dueDate != task.dueDate
            tasks[index].alarmSyncPending = task.reminderAlarmOffsetMinutes != nil
                || tasks[index].reminderAlarmOffsetMinutes != task.reminderAlarmOffsetMinutes
            tasks[index].reminderSyncError = nil
            tasks[index].reminderRestorePending = false
            if tasks[index].wasRemovedFromDrawing {
                tasks[index].reminderRemovalPending = true
                tasks[index].reminderRestorePending = true
            }
            reminderStateRevision += 1
            persist()
            resumeReminderLifecycle()
            startReminderSync(includePreviousErrors: false)
            await refreshReminderStatuses()
        } catch is CancellationError {
            return
        } catch {
            guard reminderSessionGeneration == sessionGeneration,
                  noteID == configuredNoteID else { return }
            let message = Self.reminderMessage(for: error)
            setTaskSyncError(message, for: taskID)
            reminderErrorMessage = message
            persist()
        }
    }

    func retryReminderSync() {
        for task in tasks where task.reminderRemovalPending || task.reminderRestorePending {
            retryReminderSync(for: task.id)
        }
        startReminderSync(includePreviousErrors: true)
    }

    func awaitReminderOperations() async {
        while scheduledReminderOperations > 0 || !reminderOperationIDs.isEmpty {
            await withCheckedContinuation { continuation in
                reminderIdleWaiters.append(continuation)
            }
        }
    }

    func refreshReminderStatuses() async {
        if let reminderStatusTask {
            reminderStatusNeedsRefresh = true
            await reminderStatusTask.value
            return
        }

        guard reminderStatusTask == nil,
              let reminderService,
              let configuredNoteID = noteID else { return }
        let requests = tasks.compactMap { task -> ReminderLookupRequest? in
            guard task.reminderIdentifier != nil else { return nil }
            return ReminderLookupRequest(
                taskIdentifier: task.id,
                reminderIdentifier: task.reminderIdentifier,
                calendarIdentifier: task.reminderCalendarIdentifier
            )
        }
        guard !requests.isEmpty else { return }

        let sessionGeneration = reminderSessionGeneration
        let stateRevision = reminderStateRevision
        let token = UUID()
        reminderStatusToken = token
        let statusTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.reminderStatusToken == token {
                    self.reminderStatusTask = nil
                    self.reminderStatusToken = nil
                    if self.reminderStatusNeedsRefresh {
                        self.reminderStatusNeedsRefresh = false
                        Task { [weak self] in
                            await self?.refreshReminderStatuses()
                        }
                    }
                }
            }
            do {
                let snapshot = try await reminderService.fetchReminderRecords(for: requests)
                guard !Task.isCancelled,
                      self.reminderSessionGeneration == sessionGeneration,
                      self.noteID == configuredNoteID else { return }
                guard self.reminderStateRevision == stateRevision else {
                    self.reminderStatusNeedsRefresh = true
                    return
                }
                self.applyReminderSnapshot(snapshot)
            } catch ReminderServiceError.statusReadUnsupported {
                // Older injected stores intentionally have no readback support.
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.reminderSessionGeneration == sessionGeneration,
                      self.noteID == configuredNoteID else { return }
                guard self.reminderStateRevision == stateRevision else {
                    self.reminderStatusNeedsRefresh = true
                    return
                }
                self.reminderErrorMessage = Self.reminderMessage(for: error)
            }
        }
        reminderStatusTask = statusTask
        await statusTask.value
    }

    func reminderPreferencesDidChange() {
        refreshReminderRouting()
    }

    /// Finishes the latest delayed recognition and any resulting reminder work.
    /// Automatic mode gets a fresh stability delay after the final snapshot, so
    /// leaving the editor cannot export a partly drawn task or strand a valid one.
    /// The caller may safely deactivate the session after this returns.
    func finishPendingRecognition() async {
        guard let configuredNoteID = noteID else { return }
        let sessionGeneration = reminderSessionGeneration
        automaticCreationSuppressionCount += 1
        let epoch = sessionEpoch
        finishDrainCount += 1
        let interruptedAutomaticCreation = automaticCreationTask
        cancelAutomaticCreation()
        var releasedAutomaticCreationSuppression = false
        defer {
            if !releasedAutomaticCreationSuppression {
                if sessionEpoch == epoch {
                    automaticCreationSuppressionCount -= 1
                    finishDrainCount -= 1
                    if automaticCreationSuppressionCount == 0 {
                        scheduleAutomaticCreation()
                    }
                }
            }
        }

        // A canceled stability sleep exits immediately. If creation had already
        // started, await its idempotent EventKit operation so deactivation cannot
        // discard the linkage after the external reminder was committed.
        if let interruptedAutomaticCreation {
            await interruptedAutomaticCreation.value
        }
        guard sessionEpoch == epoch, noteID == configuredNoteID else { return }

        debounceTask?.cancel()
        debounceTask = nil
        if pendingRecognition == nil, committedRevision != generation,
           activeRecognition?.revision != generation,
           let latestDrawingData {
            pendingRecognition = (latestDrawingData, generation)
        }
        while sessionEpoch == epoch,
              reminderSessionGeneration == sessionGeneration,
              noteID == configuredNoteID {
            debounceTask?.cancel()
            debounceTask = nil
            while sessionEpoch == epoch,
                  reminderSessionGeneration == sessionGeneration,
                  noteID == configuredNoteID {
                startRecognitionIfPossible()
                guard let recognitionTask else { break }
                await recognitionTask.value
                await Task.yield()
            }
            while sessionEpoch == epoch,
                  reminderSessionGeneration == sessionGeneration,
                  noteID == configuredNoteID,
                  let syncTask = reminderSyncTask {
                await syncTask.value
                await Task.yield()
            }
            while sessionEpoch == epoch,
                  reminderSessionGeneration == sessionGeneration,
                  noteID == configuredNoteID,
                  let removalTask = removalTasks.values.first {
                await removalTask.value
                await Task.yield()
            }
            // A delayed PencilKit commit can arrive while reminder I/O is in
            // progress. Drain that newer snapshot before releasing suppression.
            if pendingRecognition == nil, recognitionTask == nil,
               debounceTask == nil { break }
        }

        guard sessionEpoch == epoch, noteID == configuredNoteID else { return }
        automaticCreationSuppressionCount -= 1
        releasedAutomaticCreationSuppression = true
        finishDrainCount -= 1
        guard automaticCreationSuppressionCount == 0,
              reminderSessionGeneration == sessionGeneration,
              noteID == configuredNoteID else { return }
        scheduleAutomaticCreation()
        while reminderSessionGeneration == sessionGeneration,
              noteID == configuredNoteID,
              let pendingAutomaticCreation = automaticCreationTask {
            await pendingAutomaticCreation.value
            await Task.yield()
        }
        guard sessionEpoch == epoch, noteID == configuredNoteID else { return }
        if pendingRecognition != nil || recognitionTask != nil || debounceTask != nil {
            await finishPendingRecognition()
        }
    }

    func deactivate() {
        cancelAutomaticCreation()
        resolveReminderRouting = nil
        routingDecision = nil
        isDestinationSelectionActive = false
        isDrawingActive = false
        finishDrainCount = 0
        automaticCreationSuppressionCount = 0
        reminderSessionGeneration += 1
        reminderSyncTask?.cancel()
        reminderSyncTask = nil
        reminderSyncNeedsAnotherPass = false
        reminderStatusTask?.cancel()
        reminderStatusTask = nil
        reminderStatusToken = nil
        reminderStatusNeedsRefresh = false
        reminderStateRevision += 1
        creatingTaskIDs.removeAll()
        removalTasks.values.forEach { $0.cancel() }
        removalTasks.removeAll()
        perTaskReminderOperations.removeAll()
        syncingTaskIDs.removeAll()
        reminderOperationIDs.removeAll()
        isSyncingReminders = false
        reminderErrorMessage = nil
        generation += 1
        sessionEpoch += 1
        debounceTask?.cancel()
        debounceTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionToken = nil
        activeRecognition = nil
        pendingRecognition = nil
        deferredRecognition = nil
        provisionalTaskIDs.removeAll()
        committedRevision = -1
        isAnalyzing = false
        latestDrawingData = nil
        legacyReferenceDate = nil
        didBeginDrawingActivity = false
        initialDrawingInkBounds = nil
        noteID = nil
        saveTasks = nil
    }

    private var recognitionIsStable: Bool {
        noteID != nil && !isDrawingActive && !isAnalyzing
            && pendingRecognition == nil && debounceTask == nil
            && committedRevision == generation && provisionalTaskIDs.isEmpty
    }

    private func scheduleRecognitionIfNeeded() {
        guard pendingRecognition != nil, recognitionTask == nil,
              debounceTask == nil else { return }
        let epoch = sessionEpoch
        let delay = debounceDuration
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, self.sessionEpoch == epoch else { return }
            self.debounceTask = nil
            self.startRecognitionIfPossible()
        }
    }

    private func startRecognitionIfPossible() {
        guard recognitionTask == nil, let request = pendingRecognition,
              noteID != nil else { return }
        pendingRecognition = nil
        isAnalyzing = true
        errorMessage = nil
        let epoch = sessionEpoch
        let token = UUID()
        recognitionToken = token
        activeRecognition = request
        let recognize = recognize
        recognitionTask = Task { [weak self] in
            do {
                let candidates = try await recognize(request.data)
                guard let self, self.sessionEpoch == epoch,
                      self.recognitionToken == token else { return }
                if request.revision == self.generation, !self.isDrawingActive,
                   self.pendingRecognition == nil {
                    self.applyFinal(candidates, data: request.data, revision: request.revision)
                } else if self.isDrawingActive {
                    self.retainDeferred((candidates, request.data, request.revision))
                } else if let latestData = self.latestDrawingData {
                    let latestRevision = self.generation
                    let unchanged = await TaskRecognitionSnapshot.unchangedCandidates(
                        candidates, from: request.data, to: latestData
                    )
                    guard self.sessionEpoch == epoch,
                          self.recognitionToken == token else { return }
                    if self.generation == latestRevision, !self.isDrawingActive {
                        self.applyProvisional(unchanged)
                    } else if self.isDrawingActive {
                        self.retainDeferred((candidates, request.data, request.revision))
                    }
                }
            } catch is CancellationError {
                // A new drawing does not cancel this worker; deactivation does.
            } catch {
                guard let self, self.sessionEpoch == epoch,
                      self.recognitionToken == token else { return }
                if request.revision == self.generation {
                    if let localizedError = error as? LocalizedError,
                       let description = localizedError.errorDescription,
                       !description.isEmpty {
                        self.errorMessage = description
                    } else {
                        self.errorMessage = "Die Handschrift konnte nicht erkannt werden."
                    }
                }
            }
            guard let self, self.sessionEpoch == epoch,
                  self.recognitionToken == token else { return }
            self.recognitionTask = nil
            self.recognitionToken = nil
            self.activeRecognition = nil
            self.isAnalyzing = false
            if self.pendingRecognition != nil {
                if self.finishDrainCount > 0 { self.startRecognitionIfPossible() }
                else { self.scheduleRecognitionIfNeeded() }
            } else if self.recognitionIsStable {
                self.runStableSideEffects()
            }
        }
    }

    private func applyFinal(_ candidates: [TaskCandidate], data: Data, revision: Int) {
        let drawing = try? PKDrawing(data: data)
        let sampled = drawing.map(TaskRecognitionEngine.sampleVisibleGeometry) ?? []
        let candidateStrokeEvidence = drawing.map { drawing in
            candidates.map {
                CheckboxRemovalEvidence.strokeEvidence(
                    in: drawing, sampled: sampled, near: $0.bounds
                )
            }
        } ?? []
        var merged = Self.merge(
            candidates, with: tasks, retaining: creatingTaskIDs,
            candidateStrokeEvidence: candidateStrokeEvidence
        )
        if let drawing {
            for index in merged.indices {
                if merged[index].isPresent {
                    let samples = CheckboxRemovalEvidence.samples(in: sampled, near: merged[index].bounds)
                    if samples.count >= 12 { merged[index].checkboxInkEvidence = samples }
                    merged[index].checkboxStrokeEvidence = CheckboxRemovalEvidence.strokeEvidence(
                        in: drawing, sampled: sampled, near: merged[index].bounds
                    )
                    if merged[index].wasRemovedFromDrawing {
                        merged[index].wasRemovedFromDrawing = false
                        // Deletion might have completed while Undo was being recognized.
                        merged[index].reminderRemovalPending = false
                        if removalTasks[merged[index].id] == nil,
                           merged[index].reminderStatus != .deleted {
                            merged[index].reminderRestorePending = false
                        }
                    }
                } else if !merged[index].wasRemovedFromDrawing,
                          !CheckboxRemovalEvidence.wasMoved(
                            merged[index].checkboxStrokeEvidence ?? [], in: drawing
                          ),
                          let evidence = merged[index].checkboxInkEvidence,
                          CheckboxRemovalEvidence.provesRemoval(
                            evidence,
                            current: CheckboxRemovalEvidence.samples(in: sampled, near: merged[index].bounds)
                          ) {
                    merged[index].wasRemovedFromDrawing = true
                    if merged[index].reminderIdentifier != nil,
                       merged[index].reminderStatus != .deleted {
                        merged[index].reminderRemovalPending = true
                        merged[index].reminderRestorePending = true
                    }
                }
            }
        }
        for index in candidates.indices where merged.indices.contains(index) {
            let wasNew = provisionalTaskIDs.contains(merged[index].id)
                || !tasks.contains(where: { $0.id == merged[index].id })
            if wasNew {
                let nearby = merged[index].bounds.insetBy(dx: -6, dy: -6)
                let existingInkAtCandidate = initialDrawingInkBounds?.contains {
                    $0.intersects(nearby)
                } ?? true
                let trustworthyNewRow = didBeginDrawingActivity
                    && !existingInkAtCandidate
                let trusted = newTaskReferenceIsTrusted || trustworthyNewRow
                merged[index].dueDateReferenceDate = trusted
                    ? TaskDueDate(date: Date())
                    : (legacyReferenceDate ?? TaskDueDate(date: Date()))
                merged[index].dueDateReferenceIsTrusted = trusted
            } else if merged[index].dueDateReferenceDate == nil {
                merged[index].dueDateReferenceDate = legacyReferenceDate
                    ?? TaskDueDate(date: Date())
                merged[index].dueDateReferenceIsTrusted = false
            }
            let evidence = merged[index].correctedText ?? candidates[index].text
            inferDueDate(in: &merged[index], from: evidence, confidence: candidates[index].confidence)
        }
        tasks = merged
        provisionalTaskIDs.removeAll()
        committedRevision = revision
        reminderStateRevision += 1
        errorMessage = nil
    }

    private func applyProvisional(_ candidates: [TaskCandidate]) {
        guard !candidates.isEmpty else { return }
        // Existing tasks, particularly linked checkboxes, retain their current
        // state. Only new candidates appear as provisional proposals.
        let merged = Self.merge(candidates, with: tasks)
        let existingIDs = Set(tasks.map(\.id))
        for proposal in merged {
            if provisionalTaskIDs.contains(proposal.id),
               let index = tasks.firstIndex(where: { $0.id == proposal.id }) {
                tasks[index] = proposal
            } else if !existingIDs.contains(proposal.id) {
                tasks.append(proposal)
                provisionalTaskIDs.insert(proposal.id)
            }
        }
    }

    private func inspectEditedTitle(at index: Int) {
        guard tasks[index].dueDateSource == nil || tasks[index].dueDateSource == .automatic else {
            tasks[index].dueDateProposal = nil
            return
        }
        let text = tasks[index].title
        let reference = tasks[index].dueDateReferenceDate
            ?? legacyReferenceDate ?? TaskDueDate(date: Date())
        let result = TaskDueDateParser.parse(
            text, referenceDate: reference, confidence: 1,
            allowsRelativeDates: true
        )
        switch result {
        case .none:
            tasks[index].dueDateProposal = nil
        case .automatic(let suggestion), .proposal(let suggestion):
            tasks[index].dueDateProposal = suggestion
        }
    }

    private func inferDueDate(
        in task: inout RecognizedTask,
        from text: String,
        confidence: Float
    ) {
        // Manual edits and Reminders readback own even a nil value.
        guard task.dueDateSource == nil || task.dueDateSource == .automatic else { return }
        let previousText = task.dueDateLastAnalyzedText
        if confidence >= 0.85 { task.dueDateLastAnalyzedText = text }
        let reference = task.dueDateReferenceDate
            ?? legacyReferenceDate ?? TaskDueDate(date: Date())
        let result = TaskDueDateParser.parse(
            text, referenceDate: reference, confidence: confidence,
            allowsRelativeDates: task.dueDateReferenceIsTrusted
        )
        switch result {
        case .none:
            task.dueDateProposal = nil
            if task.dueDateSource == .automatic && previousText != text
                && confidence >= 0.85 {
                setAutomaticallyInferredDate(nil, in: &task)
            }
        case .proposal(let suggestion):
            task.dueDateProposal = suggestion
        case .automatic(let suggestion):
            task.dueDateProposal = nil
            setAutomaticallyInferredDate(suggestion.date, in: &task)
        }
    }

    private func setAutomaticallyInferredDate(
        _ date: TaskDueDate?, in task: inout RecognizedTask
    ) {
        guard task.dueDateSource == nil || task.dueDateSource == .automatic else { return }
        let changed = task.dueDate != date
        task.dueDate = date
        task.dueDateSource = .automatic
        if date?.hasTime != true && task.reminderAlarmOffsetMinutes != nil {
            task.reminderAlarmOffsetMinutes = nil
            if task.reminderIdentifier != nil { task.alarmSyncPending = true }
        }
        if changed && task.reminderIdentifier != nil {
            task.reminderDueDateSyncPending = true
            if task.reminderAlarmOffsetMinutes != nil { task.alarmSyncPending = true }
        }
    }

    private func retainDeferred(
        _ result: (candidates: [TaskCandidate], data: Data, revision: Int)
    ) {
        if deferredRecognition.map({ $0.revision > result.revision }) == true { return }
        deferredRecognition = result
    }

    private func runStableSideEffects() {
        persist()
        resumeReminderLifecycle()
        startReminderSync(includePreviousErrors: false)
        refreshReminderRouting()
        Task { [weak self] in await self?.refreshReminderStatuses() }
    }

    private func persist() {
        guard let noteID else { return }
        saveTasks?(tasks.filter { !provisionalTaskIDs.contains($0.id) }, noteID)
    }

    private func resumeReminderLifecycle() {
        for task in tasks where task.reminderRemovalPending {
            startReminderRemoval(for: task.id)
        }
        for task in tasks where task.reminderRestorePending && task.isPresent
            && !task.wasRemovedFromDrawing && task.reminderStatus == .deleted
            && task.reminderSyncError == nil {
            scheduleReminderOperation { [weak self] in
                await self?.restoreReminder(for: task.id)
            }
        }
    }

    private func scheduleReminderOperation(_ operation: @escaping @MainActor () async -> Void) {
        scheduledReminderOperations += 1
        Task { [weak self] in
            await operation()
            guard let self else { return }
            self.scheduledReminderOperations -= 1
            self.resumeReminderIdleWaitersIfNeeded()
        }
    }

    private func resumeReminderIdleWaitersIfNeeded() {
        guard scheduledReminderOperations == 0, reminderOperationIDs.isEmpty else { return }
        let waiters = reminderIdleWaiters
        reminderIdleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func startReminderRemoval(for taskID: UUID) {
        guard removalTasks[taskID] == nil,
              let reminderService,
              let configuredNoteID = noteID,
              let task = tasks.first(where: { $0.id == taskID }),
              task.reminderRemovalPending,
              task.reminderSyncError == nil,
              let identifier = task.reminderIdentifier else { return }
        let sessionGeneration = reminderSessionGeneration
        let operationID = beginReminderOperation(for: taskID)
        let removalTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.reminderSessionGeneration == sessionGeneration {
                    self.removalTasks[taskID] = nil
                    self.endReminderOperation(operationID, for: taskID)
                    // Undo and a second erase can arrive while restoration is
                    // nested in this worker. Recheck only after its task lock ends.
                    self.resumeReminderLifecycle()
                }
            }
            if let syncTask = self.reminderSyncTask { await syncTask.value }
            guard !Task.isCancelled,
                  self.reminderSessionGeneration == sessionGeneration,
                  self.noteID == configuredNoteID,
                  let current = self.tasks.first(where: { $0.id == taskID }),
                  current.reminderRemovalPending,
                  current.wasRemovedFromDrawing,
                  current.reminderIdentifier == identifier else { return }
            do {
                _ = try await reminderService.removeReminder(
                    identifier: identifier, taskID: taskID,
                    calendarIdentifier: current.reminderCalendarIdentifier
                )
                guard !Task.isCancelled,
                      self.reminderSessionGeneration == sessionGeneration,
                      self.noteID == configuredNoteID,
                      let index = self.tasks.firstIndex(where: {
                          $0.id == taskID && $0.reminderIdentifier == identifier
                      }) else { return }
                self.tasks[index].reminderRemovalPending = false
                self.tasks[index].reminderStatus = .deleted
                self.tasks[index].reminderSyncError = nil
                self.reminderStateRevision += 1
                self.persist()
                if self.tasks[index].isPresent && !self.tasks[index].wasRemovedFromDrawing
                    && self.tasks[index].reminderRestorePending {
                    await self.restoreReminder(for: taskID)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.reminderSessionGeneration == sessionGeneration,
                      self.noteID == configuredNoteID else { return }
                let message = Self.reminderMessage(for: error)
                self.setTaskSyncError(message, for: taskID)
                self.reminderErrorMessage = message
                self.persist()
            }
        }
        removalTasks[taskID] = removalTask
    }

    static func merge(
        _ candidates: [TaskCandidate],
        with previousTasks: [RecognizedTask],
        retaining additionallyRetainedTaskIDs: Set<UUID> = [],
        candidateStrokeEvidence: [[String]] = []
    ) -> [RecognizedTask] {
        struct Match {
            let candidateIndex: Int
            let taskIndex: Int
            let score: CGFloat
        }

        var matches: [Match] = []
        for (candidateIndex, candidate) in candidates.enumerated() {
            for (taskIndex, task) in previousTasks.enumerated() {
                if candidateStrokeEvidence.indices.contains(candidateIndex),
                   let priorStrokeEvidence = task.checkboxStrokeEvidence,
                   CheckboxRemovalEvidence.sameSource(
                       candidateStrokeEvidence[candidateIndex], priorStrokeEvidence
                   ) {
                    let distance = hypot(
                        candidate.bounds.midX - task.bounds.midX,
                        candidate.bounds.midY - task.bounds.midY
                    )
                    matches.append(Match(
                        candidateIndex: candidateIndex, taskIndex: taskIndex,
                        score: -100 + distance / max(36, max(task.bounds.width, task.bounds.height))
                    ))
                    continue
                }
                let candidateCenter = CGPoint(x: candidate.bounds.midX, y: candidate.bounds.midY)
                let taskCenter = CGPoint(x: task.bounds.midX, y: task.bounds.midY)
                let distance = hypot(candidateCenter.x - taskCenter.x, candidateCenter.y - taskCenter.y)
                let scale = max(
                    36,
                    max(
                        max(candidate.bounds.width, task.bounds.width),
                        max(candidate.bounds.height, task.bounds.height)
                    )
                )
                let normalizedDistance = distance / scale
                let overlap = intersectionOverUnion(candidate.bounds, task.bounds)
                let smallerArea = min(
                    candidate.bounds.width * candidate.bounds.height,
                    task.bounds.width * task.bounds.height
                )
                let intersection = candidate.bounds.intersection(task.bounds)
                let smallerBoxOverlap = intersection.isNull || smallerArea <= 0
                    ? 0
                    : intersection.width * intersection.height / smallerArea

                // Require both a nearby center and substantial overlap. Adjacent rows
                // must never inherit each other's identity or manual correction.
                guard normalizedDistance <= 0.38, smallerBoxOverlap >= 0.32 else { continue }
                matches.append(
                    Match(
                        candidateIndex: candidateIndex,
                        taskIndex: taskIndex,
                        score: normalizedDistance - overlap
                    )
                )
            }
        }

        var candidateToTask: [Int: Int] = [:]
        var claimedTasks = Set<Int>()
        for match in matches.sorted(by: { $0.score < $1.score }) {
            guard candidateToTask[match.candidateIndex] == nil,
                  !claimedTasks.contains(match.taskIndex) else { continue }
            candidateToTask[match.candidateIndex] = match.taskIndex
            claimedTasks.insert(match.taskIndex)
        }

        var merged: [RecognizedTask] = candidates.enumerated().map { index, candidate in
            let previous = candidateToTask[index].map { previousTasks[$0] }
            var result = previous ?? RecognizedTask(
                id: UUID(), bounds: candidate.bounds, recognizedText: candidate.text,
                correctedText: nil, confidence: candidate.confidence,
                isChecked: candidate.isChecked
            )
            result.bounds = candidate.bounds
            if result.reminderIdentifier == nil { result.recognizedText = candidate.text }
            if result.reminderIdentifier != nil && result.reminderLastSyncedIsChecked == nil {
                result.reminderLastSyncedIsChecked = previous?.isChecked
            }
            result.confidence = candidate.confidence
            result.isChecked = candidate.isChecked
            result.isPresent = true
            if candidateStrokeEvidence.indices.contains(index) {
                result.checkboxStrokeEvidence = candidateStrokeEvidence[index]
            }
            return result
        }

        // Linked tasks survive temporary OCR misses. Their last visible state is
        // retained, but `isPresent` prevents a miss from changing Reminders.
        for (index, previous) in previousTasks.enumerated()
        where !claimedTasks.contains(index)
            && (previous.reminderIdentifier != nil
                || previous.dueDate != nil
                || previous.dueDateSource != nil
                || previous.dueDateReferenceDate != nil
                || previous.dueDateProposal != nil
                || previous.isIgnored
                || previous.wasRemovedFromDrawing
                || additionallyRetainedTaskIDs.contains(previous.id)) {
            var absent = previous
            absent.isPresent = false
            merged.append(absent)
        }
        return merged
    }

    private func applyReminderSnapshot(_ snapshot: ReminderReadSnapshot) {
        var changed = false
        var statusReadError: String?

        for index in tasks.indices {
            guard tasks[index].reminderIdentifier != nil,
                  !tasks[index].reminderRemovalPending,
                  !tasks[index].wasRemovedFromDrawing else { continue }
            let taskID = tasks[index].id
            if let record = snapshot.recordsByTaskIdentifier[taskID] {
                let restoredStatus: TaskReminderStatus = record.isCompleted ? .completed : .open
                if tasks[index].reminderRestorePending,
                   tasks[index].isPresent, !tasks[index].wasRemovedFromDrawing,
                   !tasks[index].reminderRemovalPending,
                   removalTasks[taskID] == nil {
                    tasks[index].reminderRestorePending = false
                    changed = true
                }
                if tasks[index].reminderIdentifier != record.reminderIdentifier {
                    tasks[index].reminderIdentifier = record.reminderIdentifier
                    changed = true
                }
                if tasks[index].reminderCalendarIdentifier != record.calendarIdentifier {
                    tasks[index].reminderCalendarIdentifier = record.calendarIdentifier
                    changed = true
                }
                if tasks[index].reminderStatus != restoredStatus {
                    tasks[index].reminderStatus = restoredStatus
                    changed = true
                }
                if !tasks[index].reminderDueDateSyncPending,
                   tasks[index].dueDate != record.dueDate {
                    tasks[index].dueDate = record.dueDate
                    tasks[index].dueDateSource = .external
                    tasks[index].dueDateProposal = nil
                    changed = true
                }
                if tasks[index].reminderLastSyncedAlarmOffsetMinutes != record.alarmOffsetMinutes {
                    tasks[index].reminderLastSyncedAlarmOffsetMinutes = record.alarmOffsetMinutes
                    changed = true
                }
                if !tasks[index].alarmSyncPending,
                   tasks[index].reminderAlarmOffsetMinutes != record.alarmOffsetMinutes {
                    tasks[index].reminderAlarmOffsetMinutes = record.alarmOffsetMinutes
                    changed = true
                }
                if tasks[index].reminderSyncError == Self.calendarUnavailableStatusMessage
                    || tasks[index].reminderSyncError
                        == ReminderServiceError.reminderNotFound.localizedDescription {
                    tasks[index].reminderSyncError = nil
                    changed = true
                }
                continue
            }

            if let calendarIdentifier = tasks[index].reminderCalendarIdentifier {
                if snapshot.readableCalendarIdentifiers.contains(calendarIdentifier) {
                    if tasks[index].reminderStatus != .deleted {
                        tasks[index].reminderStatus = .deleted
                        changed = true
                    }
                    if tasks[index].reminderSyncError == Self.calendarUnavailableStatusMessage
                        || tasks[index].reminderSyncError
                            == ReminderServiceError.reminderNotFound.localizedDescription {
                        tasks[index].reminderSyncError = nil
                        changed = true
                    }
                } else {
                    statusReadError = Self.calendarUnavailableStatusMessage
                    if tasks[index].reminderSyncError != Self.calendarUnavailableStatusMessage {
                        tasks[index].reminderSyncError = Self.calendarUnavailableStatusMessage
                        changed = true
                    }
                }
            } else {
                statusReadError = Self.legacyStatusUnresolvedMessage
            }
        }

        if changed {
            reminderStateRevision += 1
            persist()
        }
        reminderErrorMessage = statusReadError
            ?? tasks.compactMap(\.reminderSyncError).first
        startReminderSync(includePreviousErrors: false)
    }

    private func applyRestoredReminder(_ record: ReminderRecord, toTaskAt index: Int) {
        tasks[index].reminderIdentifier = record.reminderIdentifier
        tasks[index].reminderCalendarIdentifier = record.calendarIdentifier
        tasks[index].reminderStatus = record.isCompleted ? .completed : .open
        if tasks[index].reminderDueDateSyncPending || tasks[index].dueDateSource != nil {
            tasks[index].reminderDueDateSyncPending = tasks[index].dueDate != record.dueDate
        } else {
            tasks[index].dueDate = record.dueDate
            tasks[index].dueDateSource = .external
        }
        tasks[index].reminderLastSyncedAlarmOffsetMinutes = record.alarmOffsetMinutes
        if tasks[index].alarmSyncPending {
            tasks[index].alarmSyncPending = tasks[index].reminderAlarmOffsetMinutes != record.alarmOffsetMinutes
        } else {
            tasks[index].reminderAlarmOffsetMinutes = record.alarmOffsetMinutes
        }
        tasks[index].reminderSyncError = nil
        tasks[index].reminderRestorePending = false
        reminderStateRevision += 1
        persist()
        reminderErrorMessage = tasks.compactMap(\.reminderSyncError).first
        startReminderSync(includePreviousErrors: false)
    }

    private func startReminderSync(includePreviousErrors: Bool) {
        guard let reminderService,
              let configuredNoteID = noteID else { return }

        if reminderSyncTask != nil {
            reminderSyncNeedsAnotherPass = true
            return
        }

        if includePreviousErrors {
            var clearedResolvedError = false
            for index in tasks.indices where tasks[index].reminderSyncError != nil {
                if tasks[index].reminderSyncError != Self.calendarUnavailableStatusMessage,
                   tasks[index].reminderLastSyncedIsChecked == tasks[index].isChecked,
                   !tasks[index].reminderDueDateSyncPending,
                   !tasks[index].alarmSyncPending {
                    tasks[index].reminderSyncError = nil
                    clearedResolvedError = true
                }
            }
            if clearedResolvedError {
                persist()
                reminderErrorMessage = tasks.compactMap(\.reminderSyncError).first
            }
        }

        let pending = tasks.compactMap { task -> (
            UUID, String, Bool?, Bool, TaskDueDate?, Int?, Int?
        )? in
            guard task.isPresent,
                  !task.wasRemovedFromDrawing,
                  !task.reminderRemovalPending,
                  task.reminderStatus != .deleted,
                  task.reminderSyncError != Self.calendarUnavailableStatusMessage,
                  let identifier = task.reminderIdentifier else { return nil }
            guard includePreviousErrors || task.reminderSyncError == nil else { return nil }
            let handwritingChanged = task.reminderLastSyncedIsChecked.map {
                $0 != task.isChecked
            } ?? false
            guard handwritingChanged || task.reminderDueDateSyncPending
                    || task.alarmSyncPending else { return nil }
            return (
                task.id, identifier,
                handwritingChanged ? task.isChecked : nil,
                task.reminderDueDateSyncPending || task.alarmSyncPending,
                task.dueDate, task.reminderAlarmOffsetMinutes,
                task.reminderLastSyncedAlarmOffsetMinutes
            )
        }
        guard !pending.isEmpty else { return }

        let sessionGeneration = reminderSessionGeneration
        syncingTaskIDs.formUnion(pending.map { $0.0 })
        let operationID = beginReminderOperation()
        reminderSyncNeedsAnotherPass = false
        reminderSyncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.syncingTaskIDs.subtract(pending.map { $0.0 })
                self.endReminderOperation(operationID)
                if self.reminderSessionGeneration == sessionGeneration,
                   self.noteID == configuredNoteID {
                    self.reminderSyncTask = nil
                    if self.reminderSyncNeedsAnotherPass {
                        self.reminderSyncNeedsAnotherPass = false
                        self.startReminderSync(includePreviousErrors: false)
                    }
                }
            }

            for (taskID, identifier, isCompleted, syncSchedule, dueDate,
                 alarmOffsetMinutes, previousAlarmOffsetMinutes) in pending {
                guard !Task.isCancelled,
                      self.reminderSessionGeneration == sessionGeneration,
                      self.noteID == configuredNoteID else { return }
                do {
                    if let isCompleted {
                        try await reminderService.updateReminderCompletion(
                            identifier: identifier,
                            isCompleted: isCompleted
                        )
                        guard !Task.isCancelled,
                              self.reminderSessionGeneration == sessionGeneration,
                              self.noteID == configuredNoteID,
                              let index = self.tasks.firstIndex(where: {
                                  $0.id == taskID && $0.reminderIdentifier == identifier
                              }) else { return }
                        self.tasks[index].reminderLastSyncedIsChecked = isCompleted
                        self.tasks[index].reminderStatus = isCompleted ? .completed : .open
                        self.reminderStateRevision += 1
                        self.persist()
                    }
                    if syncSchedule {
                        try await reminderService.updateReminderSchedule(
                            identifier: identifier, dueDate: dueDate,
                            alarmOffsetMinutes: alarmOffsetMinutes,
                            previousAlarmOffsetMinutes: previousAlarmOffsetMinutes
                        )
                    }
                    guard !Task.isCancelled,
                          self.reminderSessionGeneration == sessionGeneration,
                          self.noteID == configuredNoteID,
                          let index = self.tasks.firstIndex(where: {
                              $0.id == taskID && $0.reminderIdentifier == identifier
                          }) else { return }
                    if syncSchedule {
                        self.tasks[index].reminderDueDateSyncPending = self.tasks[index].dueDate != dueDate
                        self.tasks[index].alarmSyncPending = self.tasks[index].reminderAlarmOffsetMinutes != alarmOffsetMinutes
                        self.tasks[index].reminderLastSyncedAlarmOffsetMinutes = alarmOffsetMinutes
                    }
                    self.tasks[index].reminderSyncError = nil
                    self.reminderStateRevision += 1
                    self.persist()
                    Task { [weak self] in
                        await self?.refreshReminderStatuses()
                    }
                    if (isCompleted.map { self.tasks[index].isChecked != $0 } ?? false)
                        || self.tasks[index].reminderDueDateSyncPending
                        || self.tasks[index].alarmSyncPending {
                        self.reminderSyncNeedsAnotherPass = true
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.reminderSessionGeneration == sessionGeneration,
                          self.noteID == configuredNoteID else { return }
                    let message = Self.reminderMessage(for: error)
                    self.setTaskSyncError(message, for: taskID)
                    self.reminderErrorMessage = message
                    self.persist()
                }
            }

            if self.reminderSessionGeneration == sessionGeneration,
               self.noteID == configuredNoteID,
               !self.tasks.contains(where: { $0.reminderSyncError != nil }) {
                self.reminderErrorMessage = nil
            }
        }
    }

    private func scheduleAutomaticCreation() {
        guard automaticCreationTask == nil,
              permitsAutomaticCreation,
              let reminderService,
              reminderService.automaticallyCreateReminders,
              reminderService.hasAccess,
              hasAvailableRoutingTarget(in: reminderService),
              automaticCreationSuppressionCount == 0,
              !isDestinationSelectionActive,
              recognitionIsStable,
              let configuredNoteID = noteID,
              tasks.contains(where: Self.isEligibleForAutomaticCreation) else { return }

        let requestedRecognitionGeneration = generation
        let requestedSessionGeneration = reminderSessionGeneration
        let token = UUID()
        automaticCreationToken = token
        let delay = autoCreationDelay
        automaticCreationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            defer {
                if self.automaticCreationToken == token {
                    self.automaticCreationTask = nil
                    self.automaticCreationToken = nil
                }
            }
            guard !Task.isCancelled,
                  self.automaticCreationToken == token,
                  self.generation == requestedRecognitionGeneration,
                  self.reminderSessionGeneration == requestedSessionGeneration,
                  self.noteID == configuredNoteID,
                  self.recognitionIsStable,
                  reminderService.automaticallyCreateReminders,
                  reminderService.hasAccess,
                  self.hasAvailableRoutingTarget(in: reminderService),
                  !self.isDestinationSelectionActive else { return }

            let eligibleIDs = self.tasks
                .filter(Self.isEligibleForAutomaticCreation)
                .map(\.id)
            for taskID in eligibleIDs {
                guard !Task.isCancelled,
                      self.automaticCreationToken == token,
                      self.generation == requestedRecognitionGeneration,
                      self.reminderSessionGeneration == requestedSessionGeneration,
                      self.noteID == configuredNoteID,
                      self.recognitionIsStable,
                      reminderService.automaticallyCreateReminders else { return }
                await self.createReminder(for: taskID)
            }
        }
    }

    private func cancelAutomaticCreation() {
        automaticCreationTask?.cancel()
        automaticCreationTask = nil
        automaticCreationToken = nil
    }

    private var presentTaskTitles: [String] {
        tasks.filter { $0.isPresent && !$0.isIgnored }.map(\.title)
    }

    private func hasAvailableRoutingTarget(in service: ReminderService) -> Bool {
        if resolveReminderRouting != nil {
            guard let routingDecision,
                  !routingDecision.requiresConfirmation,
                  let targetListID = routingDecision.targetListID else { return false }
            return service.lists.contains { $0.id == targetListID }
        }
        return service.selectedListTitle != nil
    }

    private static func isEligibleForAutomaticCreation(_ task: RecognizedTask) -> Bool {
        guard task.isPresent,
              !task.isIgnored,
              !task.wasRemovedFromDrawing,
              task.reminderIdentifier == nil,
              task.reminderSyncError == nil,
              !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let hasManualTitle = task.correctedText.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        return hasManualTitle || task.confidence >= 0.65
    }

    private func setTaskSyncError(_ message: String?, for taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].reminderSyncError = message
    }

    private func beginReminderOperation(for taskID: UUID? = nil) -> UUID {
        let id = UUID()
        reminderOperationIDs.insert(id)
        if let taskID { perTaskReminderOperations[taskID, default: []].insert(id) }
        isSyncingReminders = true
        reminderOperationRevision &+= 1
        return id
    }

    private func endReminderOperation(_ id: UUID, for taskID: UUID? = nil) {
        reminderOperationIDs.remove(id)
        if let taskID {
            perTaskReminderOperations[taskID]?.remove(id)
            if perTaskReminderOperations[taskID]?.isEmpty == true {
                perTaskReminderOperations[taskID] = nil
            }
        }
        isSyncingReminders = !reminderOperationIDs.isEmpty
        reminderOperationRevision &+= 1
        resumeReminderIdleWaitersIfNeeded()
    }

    private static func reminderMessage(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    private static let calendarUnavailableStatusMessage =
        "Die verknüpfte Erinnerungsliste ist derzeit nicht verfügbar."

    private static let legacyStatusUnresolvedMessage =
        "Der Status dieser älteren Verknüpfung konnte noch keiner Erinnerungsliste zugeordnet werden."

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height
            - intersection.width * intersection.height
        guard unionArea > 0 else { return 0 }
        return intersection.width * intersection.height / unionArea
    }
}
