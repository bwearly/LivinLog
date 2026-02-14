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

    private static func shareThumbnailData() -> Data? {
        // Make sure you have an image in Assets named "LivinLogLogo"
        guard let image = UIImage(named: "LivinLogLogo") else { return nil }
        return image.pngData()
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
            existing[CKShare.SystemFieldKey.title] = shareTitle as CKRecordValue
            if let data = shareThumbnailData() {
                existing[CKShare.SystemFieldKey.thumbnailImageData] = data as CKRecordValue
            }
            return existing
        }

        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let householdInContext = try context.existingObject(with: objectID) as! Household
                    persistentContainer.share([householdInContext], to: nil) { _, share, _, error in
                        if let error {
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

                        share[CKShare.SystemFieldKey.title] = shareTitle as CKRecordValue
                        if let data = shareThumbnailData() {
                            share[CKShare.SystemFieldKey.thumbnailImageData] = data as CKRecordValue
                        }
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
