//
//  RecordIdentityIndex.swift
//  Livin Log
//
//  Phase 1 (CKSyncEngine migration).
//
//  Persisted, objectID-keyed record of "what CloudKit record identity did this Core Data
//  object last have." OutboundChangeTracker needs this for local deletes: by the time
//  NSPersistentHistoryChangeRequest reports a `.delete` change, the row itself is already gone,
//  so there's nothing left to read `recordName`/`household` off of to build the CKRecord.ID to
//  delete.
//
//  Core Data has a native mechanism for this -- NSAttributeDescription's
//  preservesValueInHistoryOnDeletion flag captures an attribute's last value into the history
//  transaction's tombstone on delete. It was NOT used here: that flag has no independently
//  verifiable raw .xcdatamodel XML spelling (Apple's docs describe the Swift property; setting
//  it from raw XML is Xcode-model-editor-only as far as this investigation could confirm), and
//  writing an unverified schema attribute into a hand-edited model file risks silently-empty
//  tombstones. This small index is the verifiable alternative: plain Codable + JSON, updated
//  synchronously every time OutboundChangeTracker sees an insert/update, consulted (and pruned)
//  on delete.
import CloudKit
import Foundation

final class RecordIdentityIndex {
    struct Ref: Codable {
        let recordType: String
        let recordName: String
        let zoneName: String
        let zoneOwnerName: String

        var recordID: CKRecord.ID {
            CKRecord.ID(recordName: recordName, zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName))
        }
    }

    private let fileURL: URL
    private var entries: [String: Ref]
    private var isDirty = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Ref].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = [:]
        }
    }

    func ref(for objectIDURI: String) -> Ref? {
        entries[objectIDURI]
    }

    func set(_ ref: Ref, for objectIDURI: String) {
        entries[objectIDURI] = ref
        isDirty = true
    }

    func remove(_ objectIDURI: String) {
        entries.removeValue(forKey: objectIDURI)
        isDirty = true
    }

    /// Batches disk writes: OutboundChangeTracker calls this once per history-processing pass
    /// rather than after every individual set/remove.
    func flush() {
        guard isDirty else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
        isDirty = false
    }
}
