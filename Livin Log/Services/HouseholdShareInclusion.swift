import CoreData

func includeInHouseholdShare(
    persistentContainer: NSPersistentCloudKitContainer,
    household: Household,
    objects: [NSManagedObject],
    label: String
) {
    guard !objects.isEmpty else { return }

    do {
        let sharesByID = try persistentContainer.fetchShares(matching: [household.objectID])
        guard let householdShare = sharesByID[household.objectID] else {
            print("ℹ️ No household share exists yet; \(label) will remain private")
#if DEBUG
            debugVerifyShareAssociation(persistentContainer: persistentContainer, objects: objects, label: label)
#endif
            return
        }

        persistentContainer.share(objects, to: householdShare) { _, _, _, error in
            if let error {
                print("❌ Failed to add \(label) to share: \(error.localizedDescription)")
            } else {
                print("✅ \(label) added to household share")
            }

#if DEBUG
            debugVerifyShareAssociation(persistentContainer: persistentContainer, objects: objects, label: label)
#endif
        }
    } catch {
        print("❌ Failed to fetch household share for \(label): \(error.localizedDescription)")
#if DEBUG
        debugVerifyShareAssociation(persistentContainer: persistentContainer, objects: objects, label: label)
#endif
    }
}

#if DEBUG
private func debugVerifyShareAssociation(
    persistentContainer: NSPersistentCloudKitContainer,
    objects: [NSManagedObject],
    label: String
) {
    for object in objects {
        do {
            let sharesByID = try persistentContainer.fetchShares(matching: [object.objectID])
            if sharesByID[object.objectID] != nil {
                print("✅ DEBUG: \(label) has an associated CKShare")
            } else {
                print("ℹ️ DEBUG: \(label) does not have an associated CKShare")
            }
        } catch {
            print("❌ DEBUG: failed to verify \(label) share: \(error.localizedDescription)")
        }
    }
}
#endif
