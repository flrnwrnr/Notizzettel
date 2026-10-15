import CloudKit
import Foundation

/// Keeps CloudKit's change tokens and pending operations on disk, so editing remains
/// available offline and uploads resume after the app restarts.
@MainActor
final class CloudSyncCoordinator: NSObject, CKSyncEngineDelegate {
    private weak var store: NoteStore?
    private let directory: URL
    private let zoneID = CKRecordZone.ID(zoneName: "Notizen", ownerName: CKCurrentUserDefaultName)
    private let database = CKContainer.default().privateCloudDatabase
    private var engine: CKSyncEngine!
    private var started = false
    private let syncCycle = CloudSyncCycleGate()
    private var seeded = false
    private let initialNotes: [Note]
    private let initialOrganizationHasContent: Bool
    private let requiresInitialConflictProtection: Bool
    private var initialConflictCopiedNoteIDs = Set<UUID>()
    private var seenRecordVersions = Set<String>()
    private var initialRemoteRecordIDs = Set<CKRecord.ID>()
    private var hadError = false
    private var statePersisted = false
    private var sendTask: Task<Void, Never>?
    private var isSendingChanges = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var localRevisions: [CKRecord.ID: Int] = [:]
    // A Note and its Pages can each report the same concurrent edit. Preserve
    // the local note once per local editing generation, then allow a fresh copy
    // if the user edits it again before another remote conflict arrives.
    private var localNoteGenerations: [UUID: Int] = [:]
    private var copiedConflictGenerations: [UUID: Int] = [:]
    private struct UploadSnapshot {
        let revision: Int
        let assetURL: URL?
    }
    private var inFlightUploads: [CKRecord.ID: [UploadSnapshot]] = [:]
    private var latestRemoteDates: [CKRecord.ID: Date] = [:]

    init(store: NoteStore, directory: URL) {
        self.store = store
        self.directory = directory
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("CloudUpload-") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        initialNotes = store.notes
        initialOrganizationHasContent = !store.customers.isEmpty || !store.calendarCustomerMappings.isEmpty ||
            store.automaticallyAssignCustomers || !store.reminderRoutingExamples.isEmpty
        requiresInitialConflictProtection = !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("CloudSyncSeeded").path
        ) || !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("CloudSyncState.json").path
        )
        super.init()
        let state = try? Data(contentsOf: stateURL)
        let serialization = state.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        engine = CKSyncEngine(.init(database: database, stateSerialization: serialization, delegate: self))
    }

    private var stateURL: URL { directory.appendingPathComponent("CloudSyncState.json") }
    private var seedMarkerURL: URL { directory.appendingPathComponent("CloudSyncSeeded") }
    private var directTokenURL: URL { directory.appendingPathComponent("CloudSyncZoneToken") }

    func start() async {
        guard !started || syncCycle.isRunning else { return }
        await syncCycle.joinOrStart { [weak self] in
            await self?.runSyncCycle()
        }.value
    }

    func syncNow() async {
        await syncCycle.joinOrStart { [weak self] in
            await self?.runSyncCycle()
        }.value
    }

    private func runSyncCycle() async {
        if started {
            await runManualSync()
        } else {
            await runInitialSync()
        }
    }

    private func runInitialSync() async {
        guard !started else { return }
        started = true
        hadError = false
        seenRecordVersions.removeAll()
        store?.setCloudStatus("iCloud wird abgeglichen …")
        do {
            let status = try await CKContainer.default().accountStatus()
            guard status == .available else {
                store?.setCloudStatus("iCloud ist auf diesem Gerät nicht verfügbar")
                started = false
                return
            }
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            try await sendChangesSerialized()
            try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
            try await fetchZoneDirectly()
            seedLocalRecords()
            try await sendChangesSerialized()
            if !hadError {
                persistSeedMarkerIfSafe()
                store?.setCloudStatus("iCloud ist aktuell")
            }
        } catch {
            store?.setCloudStatus("iCloud-Sync: \(error.localizedDescription)")
            started = false
        }
    }

    private func runManualSync() async {
        hadError = false
        seenRecordVersions.removeAll()
        store?.setCloudStatus("iCloud wird abgeglichen …")
        do {
            try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
            try await fetchZoneDirectly()
            try await sendChangesSerialized()
            if !hadError {
                persistSeedMarkerIfSafe()
                store?.setCloudStatus("iCloud ist aktuell")
            }
        } catch {
            store?.setCloudStatus("iCloud-Sync: \(error.localizedDescription)")
        }
    }

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    /// Explicit zone token protects against CKSyncEngine not tracking a zone that
    /// already existed before this installation created its local engine state.
    private func fetchZoneDirectly() async throws {
        var token: CKServerChangeToken? = nil
        if let data = try? Data(contentsOf: directTokenURL) {
            token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        var retriedExpiredToken = false
        while true {
            let batch: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                        deletions: [CKDatabase.RecordZoneChange.Deletion],
                        changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                batch = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            } catch let error as CKError where error.code == .changeTokenExpired && !retriedExpiredToken {
                token = nil
                retriedExpiredToken = true
                try? FileManager.default.removeItem(at: directTokenURL)
                continue
            }
            for (_, result) in batch.modificationResultsByID {
                let modification = try result.get()
                try applyRemoteRecord(modification.record)
            }
            for deletion in batch.deletions { try applyRemoteDeletion(deletion.recordID) }
            let data = try NSKeyedArchiver.archivedData(withRootObject: batch.changeToken, requiringSecureCoding: true)
            try data.write(to: directTokenURL, options: .atomic)
            token = batch.changeToken
            if !batch.moreComing { break }
        }
    }

    private func applyRemoteRecord(_ record: CKRecord) throws {
        let version = "\(record.recordID.zoneID.zoneName)/\(record.recordID.recordName)/\(record.recordChangeTag ?? "")"
        guard !seenRecordVersions.contains(version) else { return }
        if let date = record.modificationDate,
           let latest = latestRemoteDates[record.recordID], date < latest { return }
        if engine.state.pendingRecordZoneChanges.contains(.deleteRecord(record.recordID)) {
            seenRecordVersions.insert(version)
            return
        }
        let pending = engine.state.pendingRecordZoneChanges.contains(.saveRecord(record.recordID))
        let protectedInitialNote = try preserveInitialLocalNoteIfNeeded(for: record.recordID)
        if record.recordType != "Organization",
           (pending || inFlightUploads[record.recordID]?.isEmpty == false),
           !protectedInitialNote {
            guard let store,
                  let remoteDate = store.cloudRemoteEditDate(for: record),
                  let localDate = store.cloudLocalEditDate(for: record.recordID),
                  remoteDate > localDate else {
                seenRecordVersions.insert(version)
                return
            }
            try preserveLocalNoteIfPresent(for: record.recordID)
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        }
        let preserveLocalOrganization = record.recordType == "Organization" &&
            (pending || (initialOrganizationHasContent && !seeded))
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        try store.applyCloudRecord(record, preserveLocalOrganization: preserveLocalOrganization)
        seenRecordVersions.insert(version)
        if let date = record.modificationDate { latestRemoteDates[record.recordID] = date }
        if !seeded { initialRemoteRecordIDs.insert(record.recordID) }
    }

    private func applyRemoteDeletion(_ id: CKRecord.ID) throws {
        let deletionVersion = "\(id.zoneID.zoneName)/\(id.recordName)/deleted"
        guard !seenRecordVersions.contains(deletionVersion) else { return }
        let protectedInitialNote = try preserveInitialLocalNoteIfNeeded(for: id)
        if (engine.state.pendingRecordZoneChanges.contains(.saveRecord(id)) ||
            inFlightUploads[id]?.isEmpty == false) && !protectedInitialNote {
            seenRecordVersions.insert(deletionVersion)
            return
        }
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        try store.applyCloudDeletion(id)
        seenRecordVersions.insert(deletionVersion)
        if !seeded { initialRemoteRecordIDs.insert(id) }
    }

    private func localNoteID(for recordID: CKRecord.ID, in notes: [Note]) -> UUID? {
        let name = recordID.recordName
        if name.hasPrefix("note-"), let id = UUID(uuidString: String(name.dropFirst(5))) {
            return notes.first(where: { $0.id == id })?.id
        }
        if name.hasPrefix("page-"), let id = UUID(uuidString: String(name.dropFirst(5))) {
            return notes.first(where: { $0.pageIDs.contains(id) })?.id
        }
        return nil
    }

    @discardableResult
    private func preserveInitialLocalNoteIfNeeded(for recordID: CKRecord.ID) throws -> Bool {
        guard requiresInitialConflictProtection, !seeded,
              let noteID = localNoteID(for: recordID, in: initialNotes) else { return false }
        if initialConflictCopiedNoteIDs.contains(noteID) { return true }
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        // The original page may already have arrived before its metadata record.
        // Copy the still-local note on the first matching record from either type.
        let sourceID = store.notes.first(where: { $0.id == noteID })?.id
        guard let sourceID else { throw CocoaError(.fileNoSuchFile) }
        try preserveLocalNoteIfPresent(for: CKRecord.ID(recordName: "note-\(sourceID.uuidString)", zoneID: zoneID))
        initialConflictCopiedNoteIDs.insert(noteID)
        return true
    }

    private func preserveLocalNoteIfPresent(for recordID: CKRecord.ID) throws {
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        guard let noteID = localNoteID(for: recordID, in: store.notes) else { return }
        let generation = localNoteGenerations[noteID, default: 0]
        guard copiedConflictGenerations[noteID] != generation else { return }
        let before = Set(store.notes.map(\.id))
        store.preserveCloudConflict(for: recordID)
        guard store.notes.contains(where: { !before.contains($0.id) }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        copiedConflictGenerations[noteID] = generation
    }

    private func seedLocalRecords() {
        guard !seeded else { return }
        seeded = true
        guard requiresInitialConflictProtection else { return }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for note in initialNotes where !initialRemoteRecordIDs.contains(recordID("note-\(note.id.uuidString)")) {
            changes.append(.saveRecord(recordID("note-\(note.id.uuidString)")))
            for pageID in note.pageIDs where !initialRemoteRecordIDs.contains(recordID("page-\(pageID.uuidString)")) {
                changes.append(.saveRecord(recordID("page-\(pageID.uuidString)")))
            }
        }
        enqueue(changes, countsAsLocalEdit: false)
        if initialOrganizationHasContent && !initialRemoteRecordIDs.contains(recordID("organization")) {
            queueOrganization()
        }
    }

    private func persistSeedMarkerIfSafe() {
        guard seeded, statePersisted,
              engine.state.pendingRecordZoneChanges.isEmpty,
              engine.state.pendingDatabaseChanges.isEmpty else { return }
        do { try Data("1".utf8).write(to: seedMarkerURL, options: .atomic) }
        catch { report("iCloud-Status konnte nicht gespeichert werden: \(error.localizedDescription)") }
    }

    func queueNotes(previous: [Note], current: [Note]) {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let new = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for note in current where old[note.id] != note {
            changes.append(.saveRecord(recordID("note-\(note.id.uuidString)")))
            let oldPages = Set(old[note.id]?.pageIDs ?? [])
            for id in note.pageIDs where !oldPages.contains(id) { changes.append(.saveRecord(recordID("page-\(id.uuidString)"))) }
        }
        for note in previous where new[note.id] == nil {
            changes.append(.deleteRecord(recordID("note-\(note.id.uuidString)")))
        }
        let currentPages = Set(current.flatMap(\.pageIDs))
        for id in Set(previous.flatMap(\.pageIDs)).subtracting(currentPages) {
            changes.append(.deleteRecord(recordID("page-\(id.uuidString)")))
        }
        enqueue(changes)
    }

    func queuePage(_ id: UUID) { enqueue([.saveRecord(recordID("page-\(id.uuidString)"))]) }
    func queueOrganization() { enqueue([.saveRecord(recordID("organization"))]) }

    private func enqueue(_ changes: [CKSyncEngine.PendingRecordZoneChange], countsAsLocalEdit: Bool = true) {
        guard !changes.isEmpty else { return }
        for change in changes {
            if case .saveRecord(let id) = change {
                localRevisions[id, default: 0] += 1
                if countsAsLocalEdit, let store, let noteID = localNoteID(for: id, in: store.notes) {
                    localNoteGenerations[noteID, default: 0] += 1
                }
            }
        }
        engine.state.add(pendingRecordZoneChanges: changes)
        scheduleSend()
    }

    private func scheduleSend() {
        // Engine state is serialized by stateUpdate. Trigger a send when online.
        if started {
            store?.setCloudStatus("iCloud-Änderungen werden hochgeladen …")
            sendTask?.cancel()
            sendTask = Self.scheduleUpload { [weak self] in
                guard let self else { return }
                // Only the debounce is cancellable. Clear its handle before the
                // upload begins so another edit cannot cancel a CloudKit send.
                self.sendTask = nil
                self.hadError = false
                do {
                    try await self.sendChangesSerialized()
                    if !self.hadError { self.store?.setCloudStatus("iCloud ist aktuell") }
                } catch { self.report("iCloud-Upload: \(error.localizedDescription)") }
            }
        }
    }

    // CloudKit invokes the delegate with task-local callback context. A detached
    // task prevents that context from reaching CKSyncEngine.sendChanges().
    static func scheduleUpload(
        delay: Duration = .milliseconds(600),
        operation: @MainActor @Sendable @escaping () async -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) { @MainActor in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private func sendChangesSerialized() async throws {
        if isSendingChanges {
            await withCheckedContinuation { continuation in
                sendWaiters.append(continuation)
            }
        } else {
            isSendingChanges = true
        }
        defer {
            if sendWaiters.isEmpty {
                isSendingChanges = false
            } else {
                sendWaiters.removeFirst().resume()
            }
        }
        try await engine.sendChanges()
    }

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run { self.process(event) }
    }

    private func process(_ event: CKSyncEngine.Event) {
        switch event {
        case .fetchedDatabaseChanges:
            break
        case .didFetchRecordZoneChanges(let event):
            if let error = event.error { report("iCloud-Zonenabruf: \(error.localizedDescription)") }
        case .stateUpdate(let update):
            do {
                try JSONEncoder().encode(update.stateSerialization).write(to: stateURL, options: .atomic)
                statePersisted = true
            } catch { report("iCloud-Status konnte nicht gespeichert werden: \(error.localizedDescription)") }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                do { try applyRemoteRecord(modification.record) }
                catch { report("iCloud-Daten konnten nicht gespeichert werden: \(error.localizedDescription)") }
            }
            for deletion in changes.deletions {
                do { try applyRemoteDeletion(deletion.recordID) }
                catch { report("iCloud-Löschung konnte nicht gespeichert werden: \(error.localizedDescription)") }
            }
        case .sentRecordZoneChanges(let changes):
            for saved in changes.savedRecords {
                let id = saved.recordID
                if let date = saved.modificationDate { latestRemoteDates[id] = date }
                let sentRevision = finishUpload(for: id)
                if localRevisions[id, default: 0] > sentRevision {
                    engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                    scheduleSend()
                }
            }
            for failure in changes.failedRecordSaves {
                _ = finishUpload(for: failure.record.recordID)
                if failure.error.code == .serverRecordChanged {
                    let change: CKSyncEngine.PendingRecordZoneChange = .saveRecord(failure.record.recordID)
                    if let server = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                       let remoteDate = store?.cloudRemoteEditDate(for: server),
                       let localDate = store?.cloudLocalEditDate(for: server.recordID),
                       remoteDate > localDate {
                        engine.state.add(pendingRecordZoneChanges: [change])
                        do { try applyRemoteRecord(server) }
                        catch { report("iCloud-Konflikt konnte nicht übernommen werden: \(error.localizedDescription)") }
                    } else {
                        engine.state.add(pendingRecordZoneChanges: [change])
                        scheduleSend()
                    }
                } else {
                    report("iCloud-Upload: \(failure.error.localizedDescription)")
                }
            }
            if let first = changes.failedRecordDeletes.first {
                report("iCloud-Löschung: \(first.value.localizedDescription)")
            }
        case .sentDatabaseChanges(let changes):
            if let first = changes.failedZoneSaves.first {
                report("iCloud-Zone: \(first.error.localizedDescription)")
            }
        default: break
        }
    }

    private func report(_ message: String) {
        hadError = true
        store?.setCloudStatus(message)
    }

    @discardableResult
    private func finishUpload(for id: CKRecord.ID) -> Int {
        guard var uploads = inFlightUploads[id], !uploads.isEmpty else { return 0 }
        let finished = uploads.removeFirst()
        if let asset = finished.assetURL { try? FileManager.default.removeItem(at: asset) }
        inFlightUploads[id] = uploads.isEmpty ? nil : uploads
        return finished.revision
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let (saveIDs, database) = await MainActor.run {
            let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
            var saves: [CKRecord.ID] = []
            for change in pending {
                switch change {
                case .saveRecord(let id):
                    saves.append(id)
                case .deleteRecord: break
                @unknown default: break
                }
            }
            return (saves, self.database)
        }
        var serverRecords: [CKRecord.ID: CKRecord] = [:]
        for id in saveIDs {
            if let server = try? await database.record(for: id) { serverRecords[id] = server }
        }
        let fetchedServerRecords = serverRecords
        let (saves, deletes) = await MainActor.run { () -> ([CKRecord], [CKRecord.ID]) in
            // Nothing captured before the CloudKit awaits may be used as a local
            // snapshot: a drawing can change while record(for:) is suspended.
            let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
            var saves: [CKRecord] = []
            var deletes: [CKRecord.ID] = []
            for change in pending {
                switch change {
                case .saveRecord(let id):
                    if let server = fetchedServerRecords[id],
                       let remoteDate = store?.cloudRemoteEditDate(for: server),
                       let localDate = store?.cloudLocalEditDate(for: id),
                       remoteDate > localDate {
                        do { try applyRemoteRecord(server) }
                        catch { report("iCloud-Konflikt konnte nicht übernommen werden: \(error.localizedDescription)") }
                        continue
                    }
                    guard let local = store?.cloudRecord(for: id, zoneID: zoneID) else {
                        syncEngine.state.remove(pendingRecordZoneChanges: [change])
                        continue
                    }
                    let record = fetchedServerRecords[id] ?? local
                    if record !== local {
                        let localKeys = Set(local.allKeys())
                        for key in record.allKeys() where !localKeys.contains(key) { record[key] = nil }
                        for key in localKeys { record[key] = local[key] }
                    }
                    var assetURL: URL?
                    if let asset = record["drawing"] as? CKAsset, let source = asset.fileURL {
                        let snapshot = directory.appendingPathComponent("CloudUpload-\(UUID().uuidString).drawing")
                        do {
                            try FileManager.default.copyItem(at: source, to: snapshot)
                            record["drawing"] = CKAsset(fileURL: snapshot)
                            assetURL = snapshot
                        } catch {
                            report("iCloud-Zeichnung konnte nicht vorbereitet werden: \(error.localizedDescription)")
                            continue
                        }
                    }
                    inFlightUploads[id, default: []].append(UploadSnapshot(
                        revision: localRevisions[id, default: 0], assetURL: assetURL
                    ))
                    saves.append(record)
                case .deleteRecord(let id): deletes.append(id)
                @unknown default: break
                }
            }
            return (saves, deletes)
        }
        guard !saves.isEmpty || !deletes.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: saves, recordIDsToDelete: deletes)
    }
}

/// Owns a complete fetch/send cycle independently of the UI task that requested it.
/// Main-actor registration happens before the first suspension, so startup and
/// manual requests share one cycle even when they arrive together.
@MainActor
final class CloudSyncCycleGate {
    private var inFlight: Task<Void, Never>?
    var isRunning: Bool { inFlight != nil }

    func joinOrStart(_ operation: @MainActor @Sendable @escaping () async -> Void) -> Task<Void, Never> {
        if let inFlight { return inFlight }
        let task = Task.detached(priority: .userInitiated) { @MainActor in
            defer { self.inFlight = nil }
            await operation()
        }
        inFlight = task
        return task
    }
}
