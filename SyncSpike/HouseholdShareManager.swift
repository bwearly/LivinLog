//
//  HouseholdShareManager.swift
//  SyncSpike
//
//  Creates the zone-wide CKShare. This intentionally does NOT go through
//  CKSyncEngine's pendingRecordZoneChanges/nextRecordZoneChangeBatch pipeline
//  -- every first-party sharing example (Apple's own sample-cloudkit-zonesharing,
//  swiftwithmajid.com's zone-sharing writeup) saves the CKShare directly via
//  CKDatabase.save(_:). That's the ONLY documented pattern; CKSyncEngine has
//  no API that takes a CKShare as a pending change.
//
//  KNOWN RISK (flagged before writing this file, see plan / findings report):
//  a third-party issue against apple/sample-cloudkit-sync-engine (issue #17,
//  unconfirmed by Apple) claims CKSyncEngine doesn't notice a CKShare saved
//  this way until the app relaunches. Test C/D in the spike checklist exist
//  specifically to observe whether that's true here.

import CloudKit

enum HouseholdShareManager {

    static func createShare(for zoneID: CKRecordZone.ID, in container: CKContainer) async throws -> CKShare {
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "Livin Log Spike Household" as CKRecordValue
        share.publicPermission = .readWrite

        SpikeLogger.log(SpikeLogger.share, "Saving zone-wide CKShare for zone \(zoneID)")
        let saved = try await container.privateCloudDatabase.save(share)
        guard let savedShare = saved as? CKShare else {
            throw NSError(domain: "SyncSpike", code: -1, userInfo: [NSLocalizedDescriptionKey: "Saved record was not a CKShare"])
        }
        return savedShare
    }
}
