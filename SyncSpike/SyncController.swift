//
//  SyncController.swift
//  SyncSpike
//
//  Owns one CKSyncEngine for the private DB and one for the shared DB, per
//  Apple's documented pattern (CKSyncEngine docs: "You can have multiple
//  instances of CKSyncEngine in a single process ... one syncing a person's
//  private database and another syncing their shared database.").
//
//  Modeled closely on Apple's own sample (apple/sample-cloudkit-sync-engine,
//  SyncedDatabase.swift) since that's the only first-party CKSyncEngine
//  reference implementation available -- adapted here for two databases and
//  a household record zone instead of one fixed zone.

import CloudKit
import Foundation
import UIKit
import os.log

@MainActor
final class SyncController: ObservableObject {

    /// Single instance for the whole process. SceneDelegate is instantiated by
    /// UIKit (not by us), so it needs a way to reach the same engines/items
    /// that the SwiftUI views are bound to -- a singleton is the simplest
    /// correct option for a throwaway spike.
    static let shared = SyncController()

    // EDIT THIS to match the container you create in the developer portal:
    // iCloud.<your-bundle-id>.spike
    static let containerIdentifier = "iCloud.com.blakeearly.livinlog.spike"

    let container = CKContainer(identifier: SyncController.containerIdentifier)

    private(set) var privateEngine: CKSyncEngine!
    private(set) var sharedEngine: CKSyncEngine!

    @Published var items: [SpikeItem] = []
    @Published var householdZoneID: CKRecordZone.ID?
    @Published var householdIsOwnedLocally = false
    @Published var currentShare: CKShare?
    @Published var lastError: String?

    let deviceLabel: String = UIDevice.current.name

    private var itemsByRecordName: [String: SpikeItem] = [:]

    private struct PersistedState: Codable {
        var householdZoneName: String?
        var householdZoneOwnerName: String?
        var householdIsOwnedLocally: Bool = false
        var items: [String: PersistedItem] = [:]
    }

    private struct PersistedItem: Codable {
        var title: String
        var createdBy: String
        var zoneName: String
        var zoneOwnerName: String
        var lastKnownRecordData: Data?
    }

    private let stateDirectory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncSpike", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var privateStateURL: URL { stateDirectory.appendingPathComponent("private-engine-state.json") }
    private var sharedStateURL: URL { stateDirectory.appendingPathComponent("shared-engine-state.json") }
    private var appStateURL: URL { stateDirectory.appendingPathComponent("app-state.json") }

    init() {
        loadPersistedAppState()

        let privateStateSerialization = Self.loadSerialization(from: privateStateURL)
        let sharedStateSerialization = Self.loadSerialization(from: sharedStateURL)

        var privateConfig = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: privateStateSerialization,
            delegate: self
        )
        privateConfig.automaticallySync = true
        privateEngine = CKSyncEngine(privateConfig)

        var sharedConfig = CKSyncEngine.Configuration(
            database: container.sharedCloudDatabase,
            stateSerialization: sharedStateSerialization,
            delegate: self
        )
        sharedConfig.automaticallySync = true
        sharedEngine = CKSyncEngine(sharedConfig)

        SpikeLogger.log(SpikeLogger.engine, "SyncController init. privateEngine=\(self.privateEngine!) sharedEngine=\(self.sharedEngine!)")
    }

    // MARK: - Household

    func createHousehold() async {
        let zoneName = "Household-\(UUID().uuidString)"
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        SpikeLogger.log(SpikeLogger.share, "Creating household zone \(zoneName)")

        privateEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

        do {
            try await privateEngine.sendChanges()
        } catch {
            SpikeLogger.error(SpikeLogger.share, "Failed sending zone creation: \(String(describing: error))")
            lastError = "\(error)"
            return
        }

        householdZoneID = zoneID
        householdIsOwnedLocally = true
        persistAppState()

        do {
            let share = try await HouseholdShareManager.createShare(for: zoneID, in: container)
            currentShare = share
            SpikeLogger.log(SpikeLogger.share, "Household share created: url=\(share.url?.absoluteString ?? "nil") recordID=\(share.recordID)")
        } catch {
            SpikeLogger.error(SpikeLogger.share, "Failed creating CKShare: \(String(describing: error))")
            lastError = "\(error)"
        }
    }

    /// Called from SceneDelegate.windowScene(_:userDidAcceptCloudKitShareWith:).
    func acceptShare(metadata: CKShare.Metadata) async {
        SpikeLogger.log(SpikeLogger.share, "Accepting share: zoneID=\(metadata.share.recordID.zoneID) containerID=\(metadata.containerIdentifier)")
        do {
            let acceptedShare = try await container.accept(metadata)
            SpikeLogger.log(SpikeLogger.share, "Accepted share, recordID=\(acceptedShare.recordID)")
        } catch {
            SpikeLogger.error(SpikeLogger.share, "Failed to accept share: \(String(describing: error))")
            lastError = "\(error)"
            return
        }

        do {
            try await sharedEngine.fetchChanges()
            SpikeLogger.log(SpikeLogger.share, "Triggered sharedEngine.fetchChanges() after accept")
        } catch {
            SpikeLogger.error(SpikeLogger.share, "sharedEngine.fetchChanges() failed after accept: \(String(describing: error))")
        }
    }

    // MARK: - Items

    func addItem(title: String) {
        guard let zoneID = householdZoneID else {
            SpikeLogger.error(SpikeLogger.engine, "addItem called with no household zone")
            return
        }
        let item = SpikeItem(title: title, createdBy: deviceLabel, zoneID: zoneID)
        itemsByRecordName[item.id] = item
        refreshItemsArray()
        persistAppState()

        let engine = householdIsOwnedLocally ? privateEngine! : sharedEngine!
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(item.recordID)])
        SpikeLogger.log(SpikeLogger.engine, "Queued save for item \(item.id) on \(self.engineLabel(engine))")
    }

    private func refreshItemsArray() {
        items = itemsByRecordName.values.sorted { $0.title < $1.title }
    }

    // MARK: - Persistence

    private func loadPersistedAppState() {
        guard let data = try? Data(contentsOf: appStateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }
        if let zoneName = state.householdZoneName, let ownerName = state.householdZoneOwnerName {
            householdZoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
            householdIsOwnedLocally = state.householdIsOwnedLocally
        }
        for (recordName, persisted) in state.items {
            let zoneID = CKRecordZone.ID(zoneName: persisted.zoneName, ownerName: persisted.zoneOwnerName)
            var item = SpikeItem(id: recordName, title: persisted.title, createdBy: persisted.createdBy, zoneID: zoneID)
            if let recordData = persisted.lastKnownRecordData {
                item.lastKnownRecord = Self.decodeSystemFields(recordData)
            }
            itemsByRecordName[recordName] = item
        }
        refreshItemsArray()
        SpikeLogger.log(SpikeLogger.engine, "Restored app state: household=\(state.householdZoneName ?? "none") items=\(self.itemsByRecordName.count)")
    }

    private func persistAppState() {
        var persistedItems: [String: PersistedItem] = [:]
        for (recordName, item) in itemsByRecordName {
            let recordData = item.lastKnownRecord.flatMap(Self.encodeSystemFields)
            persistedItems[recordName] = PersistedItem(
                title: item.title,
                createdBy: item.createdBy,
                zoneName: item.zoneID.zoneName,
                zoneOwnerName: item.zoneID.ownerName,
                lastKnownRecordData: recordData
            )
        }
        let state = PersistedState(
            householdZoneName: householdZoneID?.zoneName,
            householdZoneOwnerName: householdZoneID?.ownerName,
            householdIsOwnedLocally: householdIsOwnedLocally,
            items: persistedItems
        )
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: appStateURL, options: .atomic)
        } catch {
            SpikeLogger.error(SpikeLogger.engine, "Failed persisting app state: \(String(describing: error))")
        }
    }

    private static func encodeSystemFields(_ record: CKRecord) -> Data? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        return archiver.encodedData
    }

    private static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }

    private static func loadSerialization(from url: URL) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func persistSerialization(_ serialization: CKSyncEngine.State.Serialization, to url: URL) {
        do {
            let data = try JSONEncoder().encode(serialization)
            try data.write(to: url, options: .atomic)
        } catch {
            SpikeLogger.error(SpikeLogger.engine, "Failed persisting engine state: \(String(describing: error))")
        }
    }

    private func engineLabel(_ engine: CKSyncEngine) -> String {
        engine === privateEngine ? "privateEngine" : "sharedEngine"
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncController: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let label = engineLabel(syncEngine)
        SpikeLogger.log(SpikeLogger.engine, "[\(label)] event: \(event)")

        switch event {

        case .stateUpdate(let event):
            let url = (syncEngine === privateEngine) ? privateStateURL : sharedStateURL
            persistSerialization(event.stateSerialization, to: url)

        case .accountChange(let event):
            SpikeLogger.log(SpikeLogger.engine, "[\(label)] accountChange: \(String(describing: event.changeType))")

        case .fetchedDatabaseChanges(let event):
            for modification in event.modifications {
                SpikeLogger.log(SpikeLogger.engine, "[\(label)] fetchedDatabaseChanges modification zoneID=\(modification.zoneID)")
                if syncEngine === sharedEngine, householdZoneID == nil {
                    // First time we see a shared zone show up: that's the household we just accepted.
                    householdZoneID = modification.zoneID
                    householdIsOwnedLocally = false
                    persistAppState()
                    SpikeLogger.log(SpikeLogger.share, "Adopted shared household zone \(modification.zoneID)")
                }
            }
            for deletion in event.deletions {
                SpikeLogger.log(SpikeLogger.engine, "[\(label)] fetchedDatabaseChanges deletion zoneID=\(deletion.zoneID) reason=\(deletion.reason)")
                if deletion.zoneID == householdZoneID {
                    SpikeLogger.log(SpikeLogger.share, "Household zone \(deletion.zoneID) was removed (participant likely removed, or owner deleted it)")
                    itemsByRecordName.removeAll()
                    refreshItemsArray()
                    householdZoneID = nil
                    persistAppState()
                }
            }

        case .fetchedRecordZoneChanges(let event):
            var changed = false
            for modification in event.modifications {
                let record = modification.record
                if record is CKShare {
                    SpikeLogger.log(SpikeLogger.share, "[\(label)] fetched CKShare record \(record.recordID)")
                    continue
                }
                guard var item = SpikeItem(record: record) else {
                    SpikeLogger.error(SpikeLogger.engine, "[\(label)] fetched unrecognized record \(record.recordID)")
                    continue
                }
                item.lastKnownRecord = record
                itemsByRecordName[item.id] = item
                changed = true
                SpikeLogger.log(SpikeLogger.engine, "[\(label)] fetched item \(item.id) title=\(item.title)")
            }
            for deletion in event.deletions {
                if itemsByRecordName.removeValue(forKey: deletion.recordID.recordName) != nil {
                    changed = true
                    SpikeLogger.log(SpikeLogger.engine, "[\(label)] item deleted \(deletion.recordID)")
                }
            }
            if changed {
                refreshItemsArray()
                persistAppState()
            }

        case .sentRecordZoneChanges(let event):
            for saved in event.savedRecords {
                if var item = itemsByRecordName[saved.recordID.recordName] {
                    item.lastKnownRecord = saved
                    itemsByRecordName[saved.recordID.recordName] = item
                    SpikeLogger.log(SpikeLogger.engine, "[\(label)] saved item \(saved.recordID.recordName)")
                }
            }
            for failed in event.failedRecordSaves {
                let failedRecord = failed.record
                SpikeLogger.error(SpikeLogger.engine, "[\(label)] failed save \(failedRecord.recordID) code=\(failed.error.code) error=\(failed.error)")

                switch failed.error.code {
                case .serverRecordChanged:
                    guard let serverRecord = failed.error.serverRecord else {
                        SpikeLogger.error(SpikeLogger.engine, "[\(label)] serverRecordChanged with no serverRecord attached")
                        continue
                    }
                    SpikeLogger.log(SpikeLogger.engine, "[\(label)] CONFLICT on \(failedRecord.recordID) -- taking server record per spike policy")
                    if var item = SpikeItem(record: serverRecord) {
                        item.lastKnownRecord = serverRecord
                        itemsByRecordName[item.id] = item
                    }
                default:
                    break
                }
            }
            refreshItemsArray()
            persistAppState()

        case .sentDatabaseChanges:
            break

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            SpikeLogger.log(SpikeLogger.engine, "[\(label)] unknown event")
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let label = engineLabel(syncEngine)
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        SpikeLogger.log(SpikeLogger.engine, "[\(label)] nextRecordZoneChangeBatch: \(changes.count) pending change(s)")

        let itemsSnapshot = itemsByRecordName
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            guard let item = itemsSnapshot[recordID.recordName] else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return item.makeRecord()
        }
        return batch
    }
}
