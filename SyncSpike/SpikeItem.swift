//
//  SpikeItem.swift
//  SyncSpike
//

import CloudKit
import Foundation

struct SpikeItem: Identifiable, Equatable {
    let id: String
    var title: String
    var createdBy: String
    var zoneID: CKRecordZone.ID

    /// System fields (record change tag, modification date, etc.) from the last record we
    /// either fetched or successfully saved. Needed so a later save doesn't blindly clobber
    /// a newer server version -- CKSyncEngine does NOT do this for you (see SyncController).
    var lastKnownRecord: CKRecord?

    var recordID: CKRecord.ID { CKRecord.ID(recordName: id, zoneID: zoneID) }

    init(id: String = UUID().uuidString, title: String, createdBy: String, zoneID: CKRecordZone.ID) {
        self.id = id
        self.title = title
        self.createdBy = createdBy
        self.zoneID = zoneID
    }

    static func == (lhs: SpikeItem, rhs: SpikeItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.createdBy == rhs.createdBy
    }
}

extension SpikeItem {
    static let recordType: CKRecord.RecordType = "SpikeItem"

    init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
              let title = record["title"] as? String,
              let createdBy = record["createdBy"] as? String else {
            return nil
        }
        self.init(id: record.recordID.recordName, title: title, createdBy: createdBy, zoneID: record.recordID.zoneID)
        self.lastKnownRecord = record
    }

    /// Populates a CKRecord for sending. Reuses `lastKnownRecord` when we have one so the
    /// save carries the correct change tag instead of always looking like a brand-new record.
    func makeRecord() -> CKRecord {
        let record = lastKnownRecord ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        record["title"] = title
        record["createdBy"] = createdBy
        return record
    }
}
