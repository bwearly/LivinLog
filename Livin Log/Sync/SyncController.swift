//
//  SyncController.swift
//  Livin Log
//
//  Phase 1 (CKSyncEngine migration).
//
//  Owns ONE private-DB CKSyncEngine (shared-DB/sharing are out of scope until the SyncSpike
//  device tests are in -- see Phase 1 plan). Modeled directly on SyncSpike/SyncController.swift's
//  proven pattern (state serialization to Application Support, [PREFIX]-style event logging,
//  zone-ID round-tripping) rather than re-deriving CKSyncEngine usage from scratch.
//
//  This is the new visibility layer that replaces PersistenceController's disabled
//  eventChangedNotification observer -- every event logs with a "[SYNC]" prefix, not gated
//  behind #if DEBUG.

import CloudKit
import CoreData
import Foundation

final class SyncController: NSObject {

    static let shared = SyncController(container: PersistenceController.shared.container)

    private let persistentContainer: NSPersistentContainer
    private let ckContainer: CKContainer
    private var privateEngine: CKSyncEngine!

    /// Background context used only for the sync layer's own bookkeeping (history scanning,
    /// post-send ckSystemFields refresh) -- never real business-data edits, so every save made
    /// through it is authored "sync" to avoid OutboundChangeTracker re-detecting its own writes
    /// as new local changes to send.
    private let outboundContext: NSManagedObjectContext
    private let outboundTracker: OutboundChangeTracker
    private let inboundApplier: InboundChangeApplier
    private let identityIndex: RecordIdentityIndex

    private let stateDirectory: URL
    private var remoteChangeObserver: NSObjectProtocol?
    private var didSaveObserver: NSObjectProtocol?

    init(container: NSPersistentContainer) {
        self.persistentContainer = container
        self.ckContainer = CKContainer(identifier: PersistenceController.containerId)

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stateDirectory = dir

        let identityIndex = RecordIdentityIndex(fileURL: dir.appendingPathComponent("record-identity-index.json"))
        self.identityIndex = identityIndex

        let outboundContext = container.newBackgroundContext()
        outboundContext.transactionAuthor = OutboundChangeTracker.transactionAuthor
        self.outboundContext = outboundContext
        self.outboundTracker = OutboundChangeTracker(
            context: outboundContext,
            tokenFileURL: dir.appendingPathComponent("history-token.data"),
            identityIndex: identityIndex
        )

        let inboundContext = container.newBackgroundContext()
        self.inboundApplier = InboundChangeApplier(context: inboundContext, identityIndex: identityIndex)

        super.init()

        let stateSerialization = Self.loadEngineState(from: engineStateURL)
        var config = CKSyncEngine.Configuration(
            database: ckContainer.privateCloudDatabase,
            stateSerialization: stateSerialization,
            delegate: self
        )
        config.automaticallySync = true
        privateEngine = CKSyncEngine(config)

        SyncLogger.log(SyncLogger.engine, "SyncController init. engine=\(privateEngine!)")

        observeViewContextMerge()
        observeRemoteChanges()

        // Catch up on anything that happened before this launch (e.g. the app was killed
        // mid-save, or a save landed before SyncController existed this run).
        outboundTracker.processNewChanges(engine: privateEngine)
    }

    private var engineStateURL: URL { stateDirectory.appendingPathComponent("private-engine-state.json") }

    private static func loadEngineState(from url: URL) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func persistEngineState(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        try? data.write(to: engineStateURL, options: .atomic)
    }

    // MARK: - Household zone creation

    /// Call once a new Household has been saved locally -- see
    /// AppState.createInitialHousehold(name:memberName:).
    func createZone(for household: Household) {
        guard let householdID = household.id else {
            SyncLogger.error(SyncLogger.engine, "createZone called with no household.id")
            return
        }
        let zoneID = SyncRecordMapping.zoneID(householdID: householdID)
        SyncLogger.log(SyncLogger.engine, "creating zone \(zoneID) for household \(householdID)")

        privateEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        // The household row (and its initial member) were already saved locally before this is
        // called, so a history pass right now also picks up their record saves -- the zone
        // creation and the first records can go out together.
        outboundTracker.processNewChanges(engine: privateEngine)

        Task {
            do {
                try await privateEngine.sendChanges()
            } catch {
                SyncLogger.error(SyncLogger.engine, "sendChanges after zone creation failed: \(String(describing: error))")
            }
        }
    }

    // MARK: - Remote-change wiring

    private func observeRemoteChanges() {
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistentContainer.persistentStoreCoordinator,
            queue: nil
        ) { [weak self] _ in
            guard let self, let engine = self.privateEngine else { return }
            self.outboundTracker.processNewChanges(engine: engine)
        }
    }

    /// InboundChangeApplier's context is deliberately not a child of viewContext, so its saves
    /// need an explicit merge into viewContext to reach both @FetchRequest views (MoviesListView)
    /// and the manual-fetch views (MovieDetailView/AddMovieView/AnalyticsView) -- see the Phase 1
    /// plan's note on this under "Household/HouseholdMember + @FetchRequest usage."
    private func observeViewContextMerge() {
        didSaveObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let savedContext = notification.object as? NSManagedObjectContext,
                  savedContext.transactionAuthor == OutboundChangeTracker.transactionAuthor,
                  savedContext !== self.persistentContainer.viewContext else { return }
            self.persistentContainer.viewContext.perform {
                self.persistentContainer.viewContext.mergeChanges(fromContextDidSave: notification)
            }
        }
    }

    deinit {
        if let remoteChangeObserver { NotificationCenter.default.removeObserver(remoteChangeObserver) }
        if let didSaveObserver { NotificationCenter.default.removeObserver(didSaveObserver) }
    }

    // MARK: - Entity name <-> CKRecord.RecordType

    fileprivate static func entityName(for recordType: CKRecord.RecordType) -> String {
        switch recordType {
        case SyncRecordMapping.RecordType.household: return "Household"
        case SyncRecordMapping.RecordType.member: return "HouseholdMember"
        case SyncRecordMapping.RecordType.movie: return "Movie"
        case SyncRecordMapping.RecordType.feedback: return "MovieFeedback"
        case SyncRecordMapping.RecordType.viewing: return "Viewing"
        default: return recordType
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncController: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        SyncLogger.log(SyncLogger.engine, "event: \(event)")

        switch event {
        case .stateUpdate(let event):
            persistEngineState(event.stateSerialization)

        case .accountChange(let event):
            // Per Phase 1 plan: log and stop syncing, no data wipe yet.
            SyncLogger.log(SyncLogger.engine, "accountChange: \(String(describing: event.changeType)) -- Phase 1 does not react further")

        case .fetchedDatabaseChanges(let event):
            for modification in event.modifications {
                SyncLogger.log(SyncLogger.engine, "fetchedDatabaseChanges modification zoneID=\(modification.zoneID)")
            }
            for deletion in event.deletions {
                SyncLogger.log(SyncLogger.engine, "fetchedDatabaseChanges deletion zoneID=\(deletion.zoneID) reason=\(deletion.reason)")
            }

        case .fetchedRecordZoneChanges(let event):
            inboundApplier.apply(event)

        case .sentRecordZoneChanges(let event):
            handleSentRecordZoneChanges(event, syncEngine: syncEngine)

        case .sentDatabaseChanges:
            break

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            SyncLogger.log(SyncLogger.engine, "unknown event")
        }
    }

    private func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) {
        for saved in event.savedRecords {
            refreshSystemFields(saved, forRecordName: saved.recordID.recordName, recordType: saved.recordType)
        }

        var newPendingRecordChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        var newPendingZoneSaves: [CKSyncEngine.PendingDatabaseChange] = []

        for failed in event.failedRecordSaves {
            let failedRecord = failed.record
            SyncLogger.error(SyncLogger.engine, "failed save \(failedRecord.recordID) code=\(failed.error.code) error=\(failed.error)")

            switch failed.error.code {
            case .serverRecordChanged:
                // Apply server system fields (so the next send carries the right change tag),
                // then re-enqueue: since we never overwrote the local field values, the next
                // send batch naturally reapplies them on top of the server's record -- per the
                // Phase 1 plan, deliberately different from the spike's simpler "take server
                // record" policy.
                guard let serverRecord = failed.error.serverRecord else {
                    SyncLogger.error(SyncLogger.engine, "serverRecordChanged with no serverRecord attached for \(failedRecord.recordID)")
                    continue
                }
                refreshSystemFields(serverRecord, forRecordName: failedRecord.recordID.recordName, recordType: failedRecord.recordType)
                newPendingRecordChanges.append(.saveRecord(failedRecord.recordID))

            case .zoneNotFound:
                newPendingZoneSaves.append(.saveZone(CKRecordZone(zoneID: failedRecord.recordID.zoneID)))
                newPendingRecordChanges.append(.saveRecord(failedRecord.recordID))

            case .unknownItem:
                // Local copy's system fields reference a server record that's gone (e.g.
                // deleted elsewhere). Clear them so the next send creates a fresh record.
                clearSystemFields(forRecordName: failedRecord.recordID.recordName, recordType: failedRecord.recordType)
                newPendingRecordChanges.append(.saveRecord(failedRecord.recordID))

            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled:
                SyncLogger.log(SyncLogger.engine, "retryable error for \(failedRecord.recordID): \(failed.error)")

            default:
                SyncLogger.error(SyncLogger.engine, "unhandled error saving \(failedRecord.recordID): \(failed.error)")
            }
        }

        if !newPendingZoneSaves.isEmpty {
            syncEngine.state.add(pendingDatabaseChanges: newPendingZoneSaves)
        }
        if !newPendingRecordChanges.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: newPendingRecordChanges)
        }
    }

    private func refreshSystemFields(_ record: CKRecord, forRecordName recordName: String, recordType: CKRecord.RecordType) {
        let entityName = Self.entityName(for: recordType)
        let data = SyncRecordMapping.encodeSystemFields(record)
        outboundContext.performAndWait {
            guard let object: NSManagedObject = SyncRecordMapping.fetchByRecordName(entityName: entityName, recordName: recordName, context: outboundContext) else { return }
            object.setValue(data, forKey: "ckSystemFields")
            try? outboundContext.save()
        }
    }

    private func clearSystemFields(forRecordName recordName: String, recordType: CKRecord.RecordType) {
        let entityName = Self.entityName(for: recordType)
        outboundContext.performAndWait {
            guard let object: NSManagedObject = SyncRecordMapping.fetchByRecordName(entityName: entityName, recordName: recordName, context: outboundContext) else { return }
            object.setValue(nil, forKey: "ckSystemFields")
            try? outboundContext.save()
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        SyncLogger.log(SyncLogger.engine, "nextRecordZoneChangeBatch: \(changes.count) pending change(s)")

        let outboundContext = self.outboundContext
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            outboundContext.performAndWait {
                if let record = SyncRecordMapping.makeRecord(forRecordName: recordID.recordName, context: outboundContext) {
                    return record
                }
                // Pending save for something that no longer exists locally (e.g. created then
                // deleted before ever syncing) -- drop it so the engine doesn't retry forever.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
        }
        return batch
    }
}
