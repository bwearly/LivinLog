import CoreData

func includeInHouseholdShare(
    persistentContainer: NSPersistentCloudKitContainer,
    household: Household,
    objects: [NSManagedObject],
    label: String
) {
    guard !objects.isEmpty else { return }

    let privateStore = PersistenceController.shared.privateStore
    let sharedStore = PersistenceController.shared.sharedStore

    guard let householdStore = household.objectID.persistentStore else {
        print("❌ Could not resolve household store for \(label)")
        return
    }

#if DEBUG
    debugPrintStorePlacement(household: household, objects: objects, label: label)
#endif

    if householdStore == sharedStore {
        print("ℹ️ \(label) created in SHARED store; no share update needed")
        return
    }

    guard householdStore == privateStore else {
        print("❌ \(label) household is in unknown store; skipping share inclusion")
        return
    }

    let householdID = household.objectID
    let objectIDs = objects.map(\.objectID)

    persistentContainer.performBackgroundTask { bgContext in
        do {
            guard let hh = try bgContext.existingObject(with: householdID) as? Household else {
                print("❌ Failed to resolve household in background context for \(label)")
                return
            }

            let sharesByID = try persistentContainer.fetchShares(matching: [hh.objectID])
            guard let householdShare = sharesByID[hh.objectID] else {
                print("ℹ️ No household share exists yet; \(label) remains in private store")
                return
            }

            let bgObjects = try objectIDs.compactMap { objectID -> NSManagedObject? in
                try bgContext.existingObject(with: objectID)
            }
            guard !bgObjects.isEmpty else { return }

            persistentContainer.share(bgObjects, to: householdShare) { _, _, _, error in
                if let error {
                    print("❌ Failed to add \(label) to household share: \(error.localizedDescription)")
                } else {
                    print("✅ \(label) added to household share (owner/private store)")
                }
            }
        } catch {
            print("❌ Failed share inclusion for \(label): \(error.localizedDescription)")
        }
    }
}

#if DEBUG
private func debugPrintStorePlacement(household: Household, objects: [NSManagedObject], label: String) {
    let context = household.managedObjectContext
    let coordinator = context?.persistentStoreCoordinator
    let householdStore = coordinator?.persistentStore(for: household.objectID)?.url?.lastPathComponent ?? "unknown-store"

    print("🧩 [ShareInclusion] \(label) householdStore=\(householdStore)")

    for object in objects {
        let storeName = coordinator?.persistentStore(for: object.objectID)?.url?.lastPathComponent ?? "unknown-store"
        print("🧩 [ShareInclusion] \(label) object=\(object.objectID.uriRepresentation().absoluteString) store=\(storeName)")
    }
}
#endif
