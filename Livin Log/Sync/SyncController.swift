//
//  SyncController.swift
//  Livin Log
//
//  Phase 1 (CKSyncEngine migration), extended in Phase 3b for sharing.
//
//  Owns TWO CKSyncEngines, per Apple's documented pattern (CKSyncEngine docs: "You can have
//  multiple instances of CKSyncEngine in a single process ... one syncing a person's private
//  database and another syncing their shared database.") -- one for `privateCloudDatabase`
//  (households this device owns), one for `sharedCloudDatabase` (households this device has
//  joined). Modeled directly on SyncSpike/SyncController.swift's proven two-engine pattern
//  (state serialization to Application Support, [PREFIX]-style event logging, zone-ID
//  round-tripping) rather than re-deriving CKSyncEngine usage from scratch.
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
    let ckContainer: CKContainer
    private var privateEngine: CKSyncEngine!
    private var sharedEngine: CKSyncEngine!

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

    /// Guards `cachedCurrentUserRecordName`, `hasCompletedInitialFetch`, and
    /// `initialFetchWaiters` -- written from CKSyncEngine's delegate callbacks (an arbitrary,
    /// non-main executor) and read/awaited from AppState (MainActor), so plain property access
    /// isn't safe. Mirrors the existing `CloudKitExportTracker` queue+waiters pattern in
    /// PersistenceController.swift rather than introducing a new synchronization style.
    private let identityStateQueue = DispatchQueue(label: "SyncController.identityState")
    private var cachedCurrentUserRecordName: String?
    private var privateInitialFetchCompleted = false
    private var sharedInitialFetchCompleted = false
    private var initialFetchWaiters: [(Bool) -> Void] = []
    private var currentUserRecordNameURL: URL { stateDirectory.appendingPathComponent("current-user-record-name.txt") }

    /// Zones with a zoneNotFound recovery in flight, plus the saves dropped for each. A second
    /// failure for the same zone joins the in-flight recovery instead of starting another.
    /// Explicitly `@MainActor` (the module default already makes SyncController MainActor) --
    /// only ever touched from handleEvent and the recovery Task, both on the MainActor.
    @MainActor private var zoneRecoveries: [CKRecordZone.ID: [CKSyncEngine.PendingRecordZoneChange]] = [:]

    init(container: NSPersistentContainer) {
        self.persistentContainer = container
        self.ckContainer = CKContainer(identifier: PersistenceController.containerId)

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stateDirectory = dir

        let identityIndex = RecordIdentityIndex(fileURL: dir.appendingPathComponent("record-identity-index.json"))
        self.identityIndex = identityIndex

        // Loaded synchronously, off the network, before anything else -- so a relaunch with an
        // already-linked local HouseholdMember can route straight to `.main` in AppState.start()
        // without waiting on CKContainer.userRecordID() or a CloudKit fetch. See the Phase 3a
        // plan's "must not block offline" routing rule.
        self.cachedCurrentUserRecordName = try? String(contentsOf: dir.appendingPathComponent("current-user-record-name.txt"), encoding: .utf8)

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

        // Before either engine exists (so nothing can be mid-upload): drop photo files staged
        // by a previous run whose send never reported back.
        SyncImageAsset.clearStagingDirectory()

        let privateStateSerialization = Self.loadEngineState(from: privateEngineStateURL)
        var privateConfig = CKSyncEngine.Configuration(
            database: ckContainer.privateCloudDatabase,
            stateSerialization: privateStateSerialization,
            delegate: self
        )
        privateConfig.automaticallySync = true
        privateEngine = CKSyncEngine(privateConfig)

        let sharedStateSerialization = Self.loadEngineState(from: sharedEngineStateURL)
        var sharedConfig = CKSyncEngine.Configuration(
            database: ckContainer.sharedCloudDatabase,
            stateSerialization: sharedStateSerialization,
            delegate: self
        )
        sharedConfig.automaticallySync = true
        sharedEngine = CKSyncEngine(sharedConfig)

        SyncLogger.log(SyncLogger.engine, "SyncController init. privateEngine=\(privateEngine!) sharedEngine=\(sharedEngine!)")

#if DEBUG
        SyncRecordMapping.validateRegistry(against: container.managedObjectModel)
#endif

        observeViewContextMerge()
        observeRemoteChanges()

        // Start SyncStatus's NWPathMonitor now rather than on first Settings visit, so "Offline"
        // is already accurate the first time the user looks.
        Task { @MainActor in _ = SyncStatus.shared }

        // Catch up on anything that happened before this launch (e.g. the app was killed
        // mid-save, or a save landed before SyncController existed this run).
        outboundTracker.processNewChanges(privateEngine: privateEngine, sharedEngine: sharedEngine, currentUserRecordName: currentUserRecordName)
    }

    private var privateEngineStateURL: URL { stateDirectory.appendingPathComponent("private-engine-state.json") }
    private var sharedEngineStateURL: URL { stateDirectory.appendingPathComponent("shared-engine-state.json") }

    private static func loadEngineState(from url: URL) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func persistEngineState(_ serialization: CKSyncEngine.State.Serialization, to url: URL) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func engineLabel(_ engine: CKSyncEngine) -> String {
        engine === privateEngine ? "privateEngine" : "sharedEngine"
    }

    // MARK: - Household zone creation

    /// Call once a new Household has been saved locally -- see
    /// AppState.createInitialHousehold(householdName:memberName:avatar:).
    func createZone(for household: Household) {
        guard let zoneID = SyncRecordMapping.zoneID(for: household) else {
            SyncLogger.error(SyncLogger.engine, "createZone called with no household.id and no ckSystemFields")
            return
        }
        SyncLogger.log(SyncLogger.engine, "creating zone \(zoneID) for household \(household.id?.uuidString ?? "<no id>")")

        privateEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        // The household row (and its initial member) were already saved locally before this is
        // called, so a history pass right now also picks up their record saves -- the zone
        // creation and the first records can go out together. A brand-new household is always
        // privately owned, but route through the same dual-engine call as every other pass for
        // consistency rather than a one-off privateEngine-only call.
        outboundTracker.processNewChanges(privateEngine: privateEngine, sharedEngine: sharedEngine, currentUserRecordName: currentUserRecordName)

        Task {
            do {
                try await privateEngine.sendChanges()
            } catch {
                SyncLogger.error(SyncLogger.engine, "sendChanges after zone creation failed: \(String(describing: error))")
            }
        }
    }

    // MARK: - Household teardown (Settings > Danger zone)

    /// Leader's "Delete Household": deletes the household's zone from the private database via
    /// the engine (`PendingDatabaseChange.deleteZone`, confirmed in CloudKit.swiftinterface).
    /// Confirmed in CKModifyRecordZonesOperation.h: "If you delete a record zone, CloudKit
    /// deletes any records it contains" -- the zone-wide CKShare is a record in that zone, so it
    /// goes with it. Local data is removed right away ("sync"-authored, so nothing is re-sent);
    /// if this send doesn't land, the pending zone delete persists in engine state and retries.
    func deleteOwnedHousehold(zoneID: CKRecordZone.ID) async {
        let staleZoneSaves = privateEngine.state.pendingDatabaseChanges.filter {
            if case .saveZone(let zone) = $0 { return zone.zoneID == zoneID }
            return false
        }
        if !staleZoneSaves.isEmpty {
            privateEngine.state.remove(pendingDatabaseChanges: staleZoneSaves)
        }
        privateEngine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
        await deleteLocalHousehold(zoneID: zoneID)

        do {
            try await privateEngine.sendChanges()
        } catch {
            SyncLogger.error(SyncLogger.engine, "sendChanges after zone delete failed (will retry): \(String(describing: error))")
        }
    }

    /// Participant's "Leave Household", step 1: queues any not-yet-detected local edits on the
    /// shared engine and waits for them to send, up to `timeoutSeconds`. Returns false on
    /// failure or timeout -- callers treat this as best-effort. An unstructured race rather than
    /// a task group, since a group would still wait on a `sendChanges()` that ignores
    /// cancellation.
    func flushSharedChanges(timeoutSeconds: TimeInterval) async -> Bool {
        outboundTracker.processNewChanges(privateEngine: privateEngine, sharedEngine: sharedEngine, currentUserRecordName: currentUserRecordName)
        let engine = sharedEngine!

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeOnceGate()
            Task { @MainActor in
                do {
                    try await engine.sendChanges()
                    gate.resume(continuation, with: true)
                } catch {
                    SyncLogger.error(SyncLogger.engine, "flushSharedChanges sendChanges failed: \(String(describing: error))")
                    gate.resume(continuation, with: false)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                gate.resume(continuation, with: false)
            }
        }
    }

    /// The single local-household teardown, used by every path: Leave, Delete, shared-zone loss,
    /// and private-DB zone deletion (.deleted/.purged). Deletes the local Household for `zoneID`
    /// (Cascade rules take its members/movies/etc.) on a "sync"-authored context, so
    /// OutboundChangeTracker never turns the cascade into `deleteRecord`s, and drops any pending
    /// record changes still aimed at that zone. After a successful delete it waits for the
    /// delete to merge into the main context, then reschedules reminders once, so the
    /// household's reminders are removed immediately. Returns false if no matching household
    /// exists locally or the save failed.
    @discardableResult
    func deleteLocalHousehold(zoneID: CKRecordZone.ID) async -> Bool {
        let context = persistentContainer.newBackgroundContext()
        context.transactionAuthor = OutboundChangeTracker.transactionAuthor
        var deleted = false
        context.performAndWait {
            guard let household = SyncRecordMapping.household(matchingZoneID: zoneID, context: context) else { return }
            context.delete(household)
            do {
                try context.save()
                deleted = true
            } catch {
                SyncLogger.error(SyncLogger.engine, "failed deleting local household for zone=\(zoneID): \(String(describing: error))")
                context.rollback()
            }
        }
        dropPendingRecordChanges(in: zoneID)
        guard deleted else { return false }
        SyncLogger.log(SyncLogger.engine, "deleted local data for household zone=\(zoneID)")

        // The "sync"-authored save reaches viewContext via a queued perform (the merge
        // observer); flush it so the scheduler no longer sees this household's events.
        let viewContext = persistentContainer.viewContext
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            viewContext.perform { continuation.resume() }
        }
        // `household: nil` = all remaining events, the same scope as the launch-time sync in
        // RootView (which runs before any household is selected).
        await NotificationScheduler.sync(context: viewContext, household: nil)
        return true
    }

    private func dropPendingRecordChanges(in zoneID: CKRecordZone.ID) {
        for engine in [privateEngine!, sharedEngine!] {
            removePendingRecordChanges(in: zoneID, from: engine)
        }
    }

    /// Removes and returns `engine`'s pending record changes aimed at `zoneID`.
    @discardableResult
    private func removePendingRecordChanges(in zoneID: CKRecordZone.ID, from engine: CKSyncEngine) -> [CKSyncEngine.PendingRecordZoneChange] {
        let stale = engine.state.pendingRecordZoneChanges.filter { change in
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID):
                return recordID.zoneID == zoneID
            @unknown default:
                return false
            }
        }
        if !stale.isEmpty {
            engine.state.remove(pendingRecordZoneChanges: stale)
        }
        return stale
    }

    // MARK: - Incoming share capture (Phase 3b)

    /// Set by SceneDelegate the moment a share is accepted-by-the-system (both the warm
    /// `windowScene(_:userDidAcceptCloudKitShareWith:)` hook and the cold-launch
    /// `connectionOptions.cloudKitShareMetadata` in `scene(_:willConnectTo:options:)`), always on
    /// the main thread (a UIKit app-lifecycle callback). RootView drains this on `.task`/
    /// `.onAppear` in addition to listening live for `.didReceiveCloudKitShare` -- belt-and-
    /// suspenders against the cold-launch race where SceneDelegate's hook can fire before
    /// RootView's `.onReceive` subscription exists yet, mirroring the same
    /// capture-then-drain shape `PendingInviteStore` used for the flow this replaces.
    @MainActor private(set) var pendingShareMetadata: CKShare.Metadata?

    @MainActor
    func captureIncomingShareMetadata(_ metadata: CKShare.Metadata) {
        pendingShareMetadata = metadata
        NotificationCenter.default.post(name: .didReceiveCloudKitShare, object: metadata)
    }

    @MainActor
    func consumePendingShareMetadata() -> CKShare.Metadata? {
        defer { pendingShareMetadata = nil }
        return pendingShareMetadata
    }

    // MARK: - Sharing (Phase 3b)

    /// Accepts an incoming share (from either SceneDelegate hook -- warm via
    /// `windowScene(_:userDidAcceptCloudKitShareWith:)`, cold via `scene(_:willConnectTo:options:)`'s
    /// `connectionOptions.cloudKitShareMetadata`), then kicks the shared engine to fetch the
    /// newly-accepted zone. Per the spike's flagged risk (a CKShare saved via plain
    /// `CKDatabase.save(_:)` may not wake CKSyncEngine on its own), this explicit
    /// `sharedEngine.fetchChanges()` call is required, not optional -- mirrors
    /// SyncSpike/SyncController.swift's `acceptShare(metadata:)` exactly.
    func acceptShare(metadata: CKShare.Metadata) async throws {
        SyncLogger.log(SyncLogger.engine, "accepting share zoneID=\(metadata.share.recordID.zoneID) containerID=\(metadata.containerIdentifier)")
        _ = try await ckContainer.accept(metadata)
        SyncLogger.log(SyncLogger.engine, "accepted share, triggering sharedEngine.fetchChanges()")
        do {
            try await sharedEngine.fetchChanges()
        } catch {
            // Per the spike: acceptance itself succeeded above: `container.accept` really did
            // add this device as a participant. A failed *fetch* right after doesn't undo that,
            // it only means this specific kick didn't land -- automaticallySync's own background
            // fetch (or AppState's household-polling wait) still has a chance to pick it up, so
            // this is logged, not rethrown.
            SyncLogger.error(SyncLogger.engine, "sharedEngine.fetchChanges() failed after accept: \(String(describing: error))")
        }
    }

    /// Looks up the locally-synced Household whose CloudKit zone matches `zoneID` -- used after
    /// `acceptShare` to find the household record InboundChangeApplier should have upserted by
    /// now (see `AppState`'s joining-flow poll, which calls this repeatedly under a timeout
    /// rather than assuming `fetchChanges()`'s return implies the apply+merge already landed).
    @MainActor
    func household(matchingZoneID zoneID: CKRecordZone.ID) -> Household? {
        SyncRecordMapping.household(matchingZoneID: zoneID, context: persistentContainer.viewContext)
    }

    // MARK: - Current user identity (Phase 3a)

    /// The current iCloud user record name, if already known. Populated by
    /// `resolveCurrentUserRecordName()` and by `.accountChange` events below. Synchronous and
    /// safe to poll from any thread; does not itself trigger a CloudKit round trip.
    var currentUserRecordName: String? {
        identityStateQueue.sync { cachedCurrentUserRecordName }
    }

    /// Returns the current iCloud user record name, resolving it via `CKContainer` if not
    /// already cached. Confirmed via CKContainer.h: `fetchUserRecordIDWithCompletionHandler:`
    /// is the only vendor of this value outside a `CKSyncEngine.Event.AccountChange` (which only
    /// fires on an actual account transition, not on a cold launch where the user was already
    /// signed in before this session started) -- its `NS_SWIFT_ASYNC_NAME(userRecordID())`
    /// bridges to `CKContainer.userRecordID() async throws -> CKRecord.ID`.
    func resolveCurrentUserRecordName() async -> String? {
        if let cached = currentUserRecordName { return cached }
        do {
            let recordID = try await ckContainer.userRecordID()
            setCurrentUserRecordName(recordID.recordName)
            return recordID.recordName
        } catch {
            SyncLogger.error(SyncLogger.engine, "userRecordID() failed: \(String(describing: error))")
            return nil
        }
    }

    private func setCurrentUserRecordName(_ name: String?) {
        identityStateQueue.sync {
            cachedCurrentUserRecordName = name
            let url = currentUserRecordNameURL
            if let name {
                try? name.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Initial fetch gate (Phase 3a, extended for two engines in Phase 3b)

    enum InitialFetchOutcome {
        case completed
        case timedOut
    }

    /// Resolves once BOTH engines' first `.didFetchChanges` has landed this session (immediately,
    /// if it already has), or after `timeoutSeconds`, whichever comes first. Used by
    /// `AppState.start()` to decide "no linked member locally yet" vs. "iCloud isn't reachable"
    /// without a fixed grace timer or a retry loop -- see the Phase 3a plan. Waiting on both
    /// (not just private) matters here: a second device signing into an account that only
    /// *joined* a household elsewhere has nothing to find in the private engine's fetch at all.
    func waitForInitialFetch(timeoutSeconds: TimeInterval) async -> InitialFetchOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<InitialFetchOutcome, Never>) in
            identityStateQueue.async {
                if self.privateInitialFetchCompleted && self.sharedInitialFetchCompleted {
                    continuation.resume(returning: .completed)
                    return
                }

                var resumed = false
                let resumeOnce: (Bool) -> Void = { completed in
                    self.identityStateQueue.async {
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(returning: completed ? .completed : .timedOut)
                    }
                }

                self.initialFetchWaiters.append(resumeOnce)

                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                    resumeOnce(false)
                }
            }
        }
    }

    private func markInitialFetchCompleted(engine: CKSyncEngine) {
        identityStateQueue.async {
            if engine === self.privateEngine {
                self.privateInitialFetchCompleted = true
            } else if engine === self.sharedEngine {
                self.sharedInitialFetchCompleted = true
            }
            guard self.privateInitialFetchCompleted && self.sharedInitialFetchCompleted else { return }
            let waiters = self.initialFetchWaiters
            self.initialFetchWaiters = []
            waiters.forEach { $0(true) }
        }
    }

    // MARK: - Remote-change wiring

    private func observeRemoteChanges() {
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistentContainer.persistentStoreCoordinator,
            queue: nil
        ) { [weak self] _ in
            guard let self, let privateEngine = self.privateEngine, let sharedEngine = self.sharedEngine else { return }
            self.outboundTracker.processNewChanges(privateEngine: privateEngine, sharedEngine: sharedEngine, currentUserRecordName: self.currentUserRecordName)
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

    /// From the SyncRecordMapping registry; falls back to the record type itself, as before.
    fileprivate static func entityName(for recordType: CKRecord.RecordType) -> String {
        SyncRecordMapping.spec(forRecordType: recordType)?.entityName ?? recordType
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncController: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let label = engineLabel(syncEngine)
        SyncLogger.log(SyncLogger.engine, "[\(label)] event: \(event)")

        switch event {
        case .stateUpdate(let event):
            let url = (syncEngine === privateEngine) ? privateEngineStateURL : sharedEngineStateURL
            persistEngineState(event.stateSerialization, to: url)

        case .accountChange(let event):
            handleAccountChange(event.changeType)

        case .fetchedDatabaseChanges(let event):
            for modification in event.modifications {
                SyncLogger.log(SyncLogger.engine, "[\(label)] fetchedDatabaseChanges modification zoneID=\(modification.zoneID)")
            }
            for deletion in event.deletions {
                SyncLogger.log(SyncLogger.engine, "[\(label)] fetchedDatabaseChanges deletion zoneID=\(deletion.zoneID) reason=\(deletion.reason)")
                if syncEngine === sharedEngine {
                    // Per the Phase 3b plan: only the shared engine's zone deletions represent
                    // *this device's* access being lost (the leader removed us, or stopped
                    // sharing) -- act on those.
                    await handleSharedZoneLoss(deletion.zoneID)
                } else {
                    await handlePrivateZoneDeletion(deletion, label: label)
                }
            }

        case .fetchedRecordZoneChanges(let event):
            inboundApplier.apply(event)

        case .sentRecordZoneChanges(let event):
            handleSentRecordZoneChanges(event, syncEngine: syncEngine)

        case .sentDatabaseChanges:
            break

        case .didFetchChanges:
            // Fires once per fetch cycle, success or empty -- there is no per-cycle error on
            // this event (confirmed against CloudKit.swiftinterface: `DidFetchChanges` carries
            // only `context`, not an error). A stalled/failed first fetch is instead caught by
            // `waitForInitialFetch(timeoutSeconds:)`'s timeout on the AppState side.
            markInitialFetchCompleted(engine: syncEngine)
            await MainActor.run { SyncStatus.shared.operationFinished("\(label).fetch", markSynced: true) }

        case .willFetchChanges:
            await MainActor.run { SyncStatus.shared.operationStarted("\(label).fetch") }

        case .willSendChanges:
            await MainActor.run { SyncStatus.shared.operationStarted("\(label).send") }

        case .didSendChanges:
            // `didSendChanges` carries no error either, so only count it as a successful sync
            // once nothing is left queued (a failed send leaves or re-adds its pending changes).
            let drained = !hasPendingChanges(syncEngine)
            await MainActor.run { SyncStatus.shared.operationFinished("\(label).send", markSynced: drained) }

        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            SyncLogger.log(SyncLogger.engine, "[\(label)] unknown event")
        }

        let pending = hasPendingChanges(privateEngine) || hasPendingChanges(sharedEngine)
        await MainActor.run { SyncStatus.shared.setHasPendingChanges(pending) }
    }

    private func hasPendingChanges(_ engine: CKSyncEngine) -> Bool {
        !engine.state.pendingRecordZoneChanges.isEmpty || !engine.state.pendingDatabaseChanges.isEmpty
    }

    /// A zone disappeared from this account's *private* database -- e.g. the leader deleted the
    /// household from another of their own devices. Only "Household-" zones are ours to act on;
    /// anything else (legacy NSPersistentCloudKitContainer zones) is still ignored.
    private func handlePrivateZoneDeletion(_ deletion: CKDatabase.DatabaseChange.Deletion, label: String) async {
        let zoneID = deletion.zoneID
        guard zoneID.zoneName.hasPrefix("Household-") else {
            SyncLogger.log(SyncLogger.engine, "[\(label)] legacy private-DB zone deletion ignored zoneID=\(zoneID)")
            return
        }
        switch deletion.reason {
        case .deleted, .purged:
            await handleSharedZoneLoss(zoneID)
        case .encryptedDataReset:
            // The user reset their iCloud encrypted data: the zone is gone server-side but the
            // local copy is the only surviving one. Keep it. Re-uploading it is a later item.
            SyncLogger.error(SyncLogger.engine, "[\(label)] encryptedDataReset on household zone \(zoneID): local data KEPT, not re-uploaded (not yet handled)")
        @unknown default:
            SyncLogger.error(SyncLogger.engine, "[\(label)] unknown deletion reason for household zone \(zoneID): local data kept")
        }
    }

    /// This device lost access to a household zone: the leader removed it as a participant or
    /// stopped sharing (shared DB), or the leader deleted the household from another of their
    /// own devices (private DB, see `handlePrivateZoneDeletion`). Deletes the local Household
    /// via `deleteLocalHousehold(zoneID:)`, then re-runs AppState.start() so routing re-resolves
    /// (to another household, or onboarding).
    private func handleSharedZoneLoss(_ zoneID: CKRecordZone.ID) async {
        // deleteLocalHousehold also reschedules reminders once the delete has merged.
        guard await deleteLocalHousehold(zoneID: zoneID) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .didRequestCloudKitResync, object: nil)
        }
    }

    /// Per the Phase 3a plan: a sign-out or account switch invalidates the cached user record
    /// name and must re-route immediately (the member the app resolved to may no longer be
    /// "mine"). Re-posts the existing `.didRequestCloudKitResync` notification rather than
    /// adding new AppState plumbing -- AppState already debounces a `start()` re-run from it.
    /// Posted from `Task { @MainActor in ... }` because `handleEvent` runs on an arbitrary
    /// CKSyncEngine executor, not necessarily the main thread/actor that AppState's existing
    /// subscribers for this notification assume (unlike `.NSPersistentStoreRemoteChange`, that
    /// existing subscriber doesn't hop to MainActor itself).
    private func handleAccountChange(_ changeType: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch changeType {
        case .signIn(let currentUser):
            SyncLogger.log(SyncLogger.engine, "accountChange signIn currentUser=\(currentUser.recordName)")
            setCurrentUserRecordName(currentUser.recordName)

        case .signOut(let previousUser):
            SyncLogger.log(SyncLogger.engine, "accountChange signOut previousUser=\(previousUser.recordName)")
            setCurrentUserRecordName(nil)
            Task { @MainActor in
                NotificationCenter.default.post(name: .didRequestCloudKitResync, object: nil)
            }

        case .switchAccounts(let previousUser, let currentUser):
            SyncLogger.log(SyncLogger.engine, "accountChange switchAccounts previousUser=\(previousUser.recordName) currentUser=\(currentUser.recordName)")
            setCurrentUserRecordName(nil)
            Task { @MainActor in
                NotificationCenter.default.post(name: .didRequestCloudKitResync, object: nil)
            }

        @unknown default:
            SyncLogger.log(SyncLogger.engine, "accountChange: unknown change type")
        }
    }

    private func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) {
        for saved in event.savedRecords {
            refreshSystemFields(saved, forRecordName: saved.recordID.recordName, recordType: saved.recordType)
            SyncImageAsset.removeStagedAsset(recordName: saved.recordID.recordName)
            if let upload = SyncImageAsset.pendingPhotoUploads.take(saved.recordID.recordName) {
                commitPhotoUpload(upload, forRecordName: saved.recordID.recordName, recordType: saved.recordType)
            }
        }
        // A failed save's staged photo and pending hash are no longer needed: the row's
        // photoUploadedHash is unchanged, so a retry rebuilds the record with the photo again.
        for failed in event.failedRecordSaves {
            SyncImageAsset.removeStagedAsset(recordName: failed.record.recordID.recordName)
            _ = SyncImageAsset.pendingPhotoUploads.take(failed.record.recordID.recordName)
        }

        var newPendingRecordChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        var newPendingZoneSaves: [CKSyncEngine.PendingDatabaseChange] = []
        var missingHouseholdZones: [CKRecordZone.ID: [CKSyncEngine.PendingRecordZoneChange]] = [:]

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
                let zoneID = failedRecord.recordID.zoneID
                if zoneID.zoneName.hasPrefix("Household-") {
                    // Never re-create here: the zone may have been deleted on purpose (Delete
                    // Household on another device). See recoverMissingHouseholdZone.
                    missingHouseholdZones[zoneID, default: []].append(.saveRecord(failedRecord.recordID))
                } else {
                    newPendingZoneSaves.append(.saveZone(CKRecordZone(zoneID: zoneID)))
                    newPendingRecordChanges.append(.saveRecord(failedRecord.recordID))
                }

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

        for (zoneID, failedSaves) in missingHouseholdZones {
            let dropped = failedSaves + removePendingRecordChanges(in: zoneID, from: syncEngine)
            // Unstructured, so this send's event callback isn't blocked on a fetch; pinned to
            // the MainActor (same as handleEvent and zoneRecoveries) so there's no data race.
            Task { @MainActor in
                await recoverMissingHouseholdZone(zoneID, droppedChanges: dropped, syncEngine: syncEngine)
            }
        }
    }

    /// A send hit zoneNotFound on a Household- zone. Re-creates the zone ONLY for a household on
    /// the private engine that exists locally and has never synced (`ckSystemFields == nil`:
    /// its first zone save just hasn't landed yet). A previously-synced household's zone going
    /// missing is never re-created and local data is never wiped here -- the zone-deletion
    /// event handles cleanup. Decided from local state alone, so it doesn't depend on
    /// fetchChanges() having applied any deletion first; the fetch is only a nudge.
    @MainActor
    private func recoverMissingHouseholdZone(_ zoneID: CKRecordZone.ID, droppedChanges: [CKSyncEngine.PendingRecordZoneChange], syncEngine: CKSyncEngine) async {
        let label = engineLabel(syncEngine)
        // Deletes are meaningless against a zone that's gone (or about to be re-created empty).
        let saves = droppedChanges.filter { if case .saveRecord = $0 { return true } else { return false } }

        if zoneRecoveries[zoneID] != nil {
            zoneRecoveries[zoneID]?.append(contentsOf: saves)
            SyncLogger.log(SyncLogger.engine, "[\(label)] zoneNotFound zone=\(zoneID): recovery already in flight, joined it with \(saves.count) save(s)")
            return
        }
        zoneRecoveries[zoneID] = saves
        SyncLogger.log(SyncLogger.engine, "[\(label)] zoneNotFound zone=\(zoneID): dropped \(droppedChanges.count) pending change(s), fetching")

        do {
            try await syncEngine.fetchChanges()
        } catch {
            SyncLogger.error(SyncLogger.engine, "[\(label)] zoneNotFound zone=\(zoneID): fetchChanges failed (decision doesn't depend on it): \(String(describing: error))")
        }

        let changes = zoneRecoveries.removeValue(forKey: zoneID) ?? []
        let outboundContext = self.outboundContext
        let (householdExists, hasSynced) = outboundContext.performAndWait {
            let household = SyncRecordMapping.household(matchingZoneID: zoneID, context: outboundContext)
            return (household != nil, household?.ckSystemFields != nil)
        }

        if !householdExists {
            SyncLogger.log(SyncLogger.engine, "[\(label)] zoneNotFound zone=\(zoneID): PATH=deleted, no local household, dropped \(changes.count) save(s)")
        } else if hasSynced {
            SyncLogger.error(SyncLogger.engine, "[\(label)] zoneNotFound zone=\(zoneID): PATH=missing-previously-synced, not re-creating, local data kept, dropped \(changes.count) save(s)")
        } else if syncEngine === privateEngine {
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            syncEngine.state.add(pendingRecordZoneChanges: changes)
            SyncLogger.log(SyncLogger.engine, "[\(label)] zoneNotFound zone=\(zoneID): PATH=recreate, never-synced household, re-created zone + re-queued \(changes.count) save(s)")
        } else {
            SyncLogger.error(SyncLogger.engine, "[\(label)] zoneNotFound zone=\(zoneID): PATH=shared-no-recreate, shared engine never re-creates zones, dropped \(changes.count) save(s)")
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

    /// The server now holds this photo (or none): record its hash on the row so later edits to
    /// other fields omit the photo. Local + unsynced field, "sync"-authored save.
    private func commitPhotoUpload(_ upload: SyncImageAsset.PhotoUpload, forRecordName recordName: String, recordType: CKRecord.RecordType) {
        let entityName = Self.entityName(for: recordType)
        let hash: String?
        switch upload {
        case .uploaded(let uploadedHash): hash = uploadedHash
        case .cleared: hash = nil
        }
        outboundContext.performAndWait {
            guard let object: NSManagedObject = SyncRecordMapping.fetchByRecordName(entityName: entityName, recordName: recordName, context: outboundContext),
                  object.entity.propertiesByName["photoUploadedHash"] != nil else { return }
            object.setValue(hash, forKey: "photoUploadedHash")
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

/// Resumes a continuation at most once -- see `SyncController.flushSharedChanges(timeoutSeconds:)`.
@MainActor
private final class ResumeOnceGate {
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Bool, Never>, with value: Bool) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
