//
//  CloudSharing.swift
//  Livin Log
//

import CoreData
import CloudKit
import UIKit

/// CloudKit sharing helpers.
///
/// CloudKit Console tips:
/// - Use the CloudKit Console for the same container identifier as in `PersistenceController`.
/// - For dev builds, look under the Development environment; for TestFlight/App Store, use Production.
/// - Household records are in the Private database; shared household data appears in the Shared database.
/// - CKShare records exist alongside the shared root record in the Shared database.

enum CloudSharing {
    private static let shareTitle = "Livin Log Household"
    // If you want "anyone with the link" to be able to open/join the share without being explicitly invited,
    // set `publicPermission` to `.readOnly` (safer) or `.readWrite` (anyone with link can edit).
    // We'll default to `.readOnly` and rely on explicit participant permissions for write access.
    private static let publicPermission: CKShare.ParticipantPermission = .readOnly

    private static func shareThumbnailData() -> Data? {
        // NOTE: This thumbnail is used by CloudKit's share UI (UICloudSharingController).
        // iMessage link previews for icloud.com URLs are controlled by Apple and may still show the iCloud icon.
        UIImage(named: "LivinLogLogo")?.pngData()
    }

    private static func applyShareMetadata(_ share: CKShare) {
        share[CKShare.SystemFieldKey.title] = shareTitle as CKRecordValue
        if let thumbnail = shareThumbnailData() {
            share[CKShare.SystemFieldKey.thumbnailImageData] = thumbnail as CKRecordValue
        }
        share.publicPermission = publicPermission
    }

    private static func logCloudKitError(_ error: Error, prefix: String) {
        if let ckError = error as? CKError {
            print("🟥 \(prefix) CKError code=\(ckError.code.rawValue) (\(ckError.code)) userInfo=\(ckError.userInfo)")
        } else {
            print("🟥 \(prefix):", error)
        }
    }

    static func containerIdentifier(from persistentContainer: NSPersistentCloudKitContainer) -> String {
        persistentContainer
            .persistentStoreDescriptions
            .first?
            .cloudKitContainerOptions?
            .containerIdentifier ?? ""
    }

    static func cloudKitContainer(from persistentContainer: NSPersistentCloudKitContainer) -> CKContainer {
        let identifier = containerIdentifier(from: persistentContainer)
        if identifier.isEmpty {
            return CKContainer.default()
        }
        return CKContainer(identifier: identifier)
    }

    static func accountStatus(using persistentContainer: NSPersistentCloudKitContainer) async -> CKAccountStatus {
        let container = cloudKitContainer(from: persistentContainer)
        do {
            return try await container.accountStatus()
        } catch {
            return .couldNotDetermine
        }
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
        let objectID = household.objectID
        print("ℹ️ CloudSharing start for household:", objectID)

        var didSave = false

        try await context.perform {
            if objectID.isTemporaryID {
                try context.obtainPermanentIDs(for: [household])
            }
            if context.hasChanges {
                try context.save()
                didSave = true
            }
        }

        if didSave {
            print("✅ CloudSharing saved household changes.")
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        if let existing = try? fetchShare(for: objectID, persistentContainer: persistentContainer) {
            print("ℹ️ Reusing existing CloudKit share:", existing.recordID.recordName)

            // Ensure metadata is up to date.
            applyShareMetadata(existing)

            // Persist metadata updates by re-sharing to the same CKShare.
            return try await withCheckedThrowingContinuation { continuation in
                context.perform {
                    do {
                        let householdInContext = try context.existingObject(with: objectID) as! Household
                        persistentContainer.share([householdInContext], to: existing) { _, share, _, error in
                            if let error {
                                logCloudKitError(error, prefix: "Failed updating existing share")
                                continuation.resume(throwing: error)
                                return
                            }

                            guard let share else {
                                continuation.resume(throwing: NSError(
                                    domain: "CloudSharing",
                                    code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "Updated share was nil."]
                                ))
                                return
                            }

                            applyShareMetadata(share)
                            continuation.resume(returning: share)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let householdInContext = try context.existingObject(with: objectID) as! Household
                    persistentContainer.share([householdInContext], to: nil) { _, share, _, error in
                        if let error {
                            logCloudKitError(error, prefix: "Failed creating new share")
                            continuation.resume(throwing: error)
                            return
                        }

                        guard let share else {
                            continuation.resume(throwing: NSError(
                                domain: "CloudSharing",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Share was nil."]
                            ))
                            return
                        }

                        applyShareMetadata(share)
                        print("✅ Created new CloudKit share:", share.recordID.recordName)
                        continuation.resume(returning: share)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
