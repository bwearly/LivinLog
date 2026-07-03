//
//  CloudSharing.swift
//  Livin Log
//

import CoreData
import CloudKit

/// Distinct from `PrepareShareWatchdogTimeoutError` (UICloudSharingControllerRepresentable) so
/// Settings/logs can tell "the export-idle gate itself timed out before share() was even
/// called" apart from "share()'s completion handler never fired." Experimental error for the
/// Task 3 deadlock-hypothesis test, not a permanent user-facing message.
struct ExportIdleWaitTimeoutError: LocalizedError {
    var errorDescription: String? {
        "iCloud sharing could not start because a pending sync operation did not finish in time. Please try again in a moment."
    }
}

enum CloudSharing {
    // Schema safety checklist for TestFlight / Production CloudKit:
    // 1) Any CloudKit-backed Core Data model change must be deployed from Development -> Production schema
    //    in CloudKit Dashboard before shipping TestFlight/App Store builds.
    // 2) Avoid renaming or type-changing existing CloudKit-backed attributes (for example `contextText`),
    //    unless you provide a migration strategy and deploy the updated schema first.
    // 3) TestFlight uses PRODUCTION CloudKit schema; local/simulator success against Development does not
    //    guarantee Production writes will succeed.
    static let lastShareErrorDefaultsKey = "ll_last_cloudkit_share_error"
    static let lastShareStatusDefaultsKey = "ll_last_cloudkit_share_status"

    static func containerIdentifier(from persistentContainer: NSPersistentCloudKitContainer) -> String {
        persistentContainer
            .persistentStoreDescriptions
            .first?
            .cloudKitContainerOptions?
            .containerIdentifier ?? ""
    }

    static func accountStatus(using persistentContainer: NSPersistentCloudKitContainer) async -> CKAccountStatus {
        let identifier = containerIdentifier(from: persistentContainer)
        let container = identifier.isEmpty ? CKContainer.default() : CKContainer(identifier: identifier)

        do {
            return try await container.accountStatus()
        } catch {
            return .couldNotDetermine
        }
    }

    static func isShareActionAvailable(for status: CKAccountStatus) -> Bool {
        status == .available
    }

    static func fetchShare(
        for objectID: NSManagedObjectID,
        persistentContainer: NSPersistentCloudKitContainer
    ) throws -> CKShare? {
        let shares = try persistentContainer.fetchShares(matching: [objectID])
        return shares[objectID]
    }


    static func fetchOrCreateShare(
        for household: Household,
        in context: NSManagedObjectContext,
        persistentContainer: NSPersistentCloudKitContainer
    ) async throws -> CKShare {

        // Ensure the household has a permanent ID and is saved before sharing
        try await context.perform {
            if household.objectID.isTemporaryID {
                try context.obtainPermanentIDs(for: [household])
            }
            if context.hasChanges {
                try context.save()
            }
        }

        // ✅ Resolve the PRIVATE store (owner creates share in private DB). This is
        // container-level (not context-bound), so it's resolved up front, before entering
        // context.perform, so the export-idle gate below can be awaited without blocking the
        // managed object context's queue while waiting.
        let privateStoreURL = persistentContainer.persistentStoreDescriptions
            .first(where: { $0.cloudKitContainerOptions?.databaseScope == .private })?
            .url

        let storeForShare: NSPersistentStore? = {
            if let url = privateStoreURL {
                return persistentContainer.persistentStoreCoordinator.persistentStore(for: url)
            }
            return persistentContainer.persistentStoreCoordinator.persistentStores.first
        }()

        guard let store = storeForShare else {
            throw NSError(
                domain: "CloudSharing",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve a persistent store to persist the share."]
            )
        }

        let shareAttemptID = UUID().uuidString.prefix(8)

        // --- Task 3 experiment: gate share() on export-idle for this store -----------------
        // Evidence from device captures: persistentContainer.share(...) called while an
        // export-type CKEvent is open (end=nil) on the same store is followed by neither the
        // export nor the share ever completing. This waits for that in-flight export to clear
        // before calling share(), as a direct test of the deadlock hypothesis. Diagnostic only;
        // see CloudKitSharingInvestigation.md / Task 3 summary for caveats.
        let storeIdentifier = store.identifier ?? "<nil-store-identifier>"
        if CloudKitExportTracker.shared.isExportInFlight(storeIdentifier: storeIdentifier) {
            print("⏳ [CloudSharing] export in flight, waiting store=\(storeIdentifier) attempt=\(shareAttemptID)")
            let clearedInTime = await CloudKitExportTracker.shared.waitForExportIdle(
                storeIdentifier: storeIdentifier,
                timeout: CloudKitExportTracker.exportIdleWaitTimeout
            )
            if clearedInTime {
                print("✅ [CloudSharing] export cleared, proceeding store=\(storeIdentifier) attempt=\(shareAttemptID)")
            } else {
                print("⏱️ [CloudSharing] wait-for-export-idle timed out store=\(storeIdentifier) attempt=\(shareAttemptID)")
                throw ExportIdleWaitTimeoutError()
            }
        }
        // -------------------------------------------------------------------------------------

        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    guard let householdInContext = try context.existingObject(with: household.objectID) as? Household else {
                        continuation.resume(throwing: NSError(
                            domain: "CloudSharing",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Household not found."]
                        ))
                        return
                    }

                    let householdURI = householdInContext.objectID.uriRepresentation().absoluteString
                    let storeURLString = store.url?.lastPathComponent ?? "unknown-store"
                    print("ℹ️ [CloudSharing] Creating/updating owner Household share household=\(householdURI) store=\(storeURLString) attempt=\(shareAttemptID)")

                    // Correlate against the "☁️ [CKEvent] type=export ..." lines logged by
                    // PersistenceController's eventChangedNotification observer: a share(_:to:)
                    // call typically surfaces internally as an export-type CKEvent. Comparing
                    // this timestamp (and the completion-closure timestamp below) against CKEvent
                    // start/end times shows whether the mirroring delegate is still busy
                    // (e.g. mid zone-reset) when the share call is issued.
                    print("ℹ️ [CloudSharing] Calling persistentContainer.share(...) attempt=\(shareAttemptID) at=\(ISO8601DateFormatter().string(from: Date()))")

                    persistentContainer.share([householdInContext], to: nil) { _, share, _, error in
                        print("ℹ️ [CloudSharing] share(...) completion closure fired attempt=\(shareAttemptID) at=\(ISO8601DateFormatter().string(from: Date()))")

                        if let error {
                            print("❌ [CloudSharing] Household share creation failed: \(error.localizedDescription)")
                            continuation.resume(throwing: error)
                            return
                        }

                        guard let share else {
                            continuation.resume(throwing: NSError(
                                domain: "CloudSharing",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Share was nil."]
                            ))
                            return
                        }

                        // ✅ Configure share for link-based join + read/write
                        share[CKShare.SystemFieldKey.title] =
                            (householdInContext.name ?? "Livin Log Household") as CKRecordValue
                        share.publicPermission = .readWrite

#if DEBUG
                        print("[CloudSharing] share.publicPermission=\(share.publicPermission.rawValue)")
                        if let shareURL = share.url {
                            print("[CloudSharing] share.url=\(shareURL.absoluteString)")
                        } else {
                            print("[CloudSharing] share.url=nil")
                        }
                        print("[CloudSharing] share.recordID=\(share.recordID.recordName)")
                        let debugStoreURLString = store.url?.absoluteString ?? "nil"
                        print("[CloudSharing] persisting updated share into storeURL=\(debugStoreURLString)")
#endif

                        // ✅ Persist updated share fields back to CloudKit
                        persistentContainer.persistUpdatedShare(share, in: store) { _, persistError in
                            if let persistError {
                                continuation.resume(throwing: persistError)
                                return
                            }

                            print("ℹ️ [CloudSharing] Household share persisted recordID=\(share.recordID.recordName) urlAvailable=\(share.url != nil)")

                            do {
                                let persisted = try persistentContainer.fetchShares(matching: [householdInContext.objectID])
                                let persistedShare = persisted[householdInContext.objectID]
                                let persistedRecord = persistedShare?.recordID.recordName ?? "nil"
                                print("[CloudSharing] post-persist fetchShares success=\(persistedShare != nil) recordID=\(persistedRecord)")
                            } catch {
                                print("[CloudSharing] post-persist fetchShares failed: \(error.localizedDescription)")
                            }

                            continuation.resume(returning: share)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    static func saveLastShareStatus(_ text: String) {
        UserDefaults.standard.set(text, forKey: lastShareStatusDefaultsKey)
    }

    static func saveLastShareError(_ text: String?) {
        UserDefaults.standard.set(text, forKey: lastShareErrorDefaultsKey)
    }


    static func technicalDetails(for error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)"
    }

    static func friendlySharingErrorMessage(forTechnicalDetails technicalDetails: String) -> String {
        if technicalDetails.localizedCaseInsensitiveContains("CD_moveReceipt")
            || technicalDetails.localizedCaseInsensitiveContains("Cannot create or modify field")
            || technicalDetails.localizedCaseInsensitiveContains("production schema") {
            return "iCloud sharing could not finish because the app data schema is out of sync."
        }

        return "iCloud sharing could not finish. Show technical details for debugging information."
    }

    static func stopSharing(
        share: CKShare,
        persistentContainer: NSPersistentCloudKitContainer
    ) async throws {
        let identifier = containerIdentifier(from: persistentContainer)
        let container = identifier.isEmpty ? CKContainer.default() : CKContainer(identifier: identifier)
        _ = try await container.privateCloudDatabase.deleteRecord(withID: share.recordID)
    }
    
}
