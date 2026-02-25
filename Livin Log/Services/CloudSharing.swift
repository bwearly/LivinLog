//
//  CloudSharing.swift
//  Livin Log
//

import CoreData
import CloudKit

enum CloudSharing {
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
        try await context.perform {
            if household.objectID.isTemporaryID {
                try context.obtainPermanentIDs(for: [household])
            }
            if context.hasChanges {
                try context.save()
            }
        }

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

                    persistentContainer.share([householdInContext], to: nil) { _, share, _, error in
                        if let error {
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

                        share[CKShare.SystemFieldKey.title] = (householdInContext.name ?? "Livin Log Household") as CKRecordValue
                        continuation.resume(returning: share)
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

    static func stopSharing(
        share: CKShare,
        persistentContainer: NSPersistentCloudKitContainer
    ) async throws {
        let identifier = containerIdentifier(from: persistentContainer)
        let container = identifier.isEmpty ? CKContainer.default() : CKContainer(identifier: identifier)
        _ = try await container.privateCloudDatabase.deleteRecord(withID: share.recordID)
    }
}
