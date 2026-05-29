import CoreData

/// Household-owned Core Data objects inherit CloudKit sharing through their
/// relationship to `Household`. Do not call `NSPersistentCloudKitContainer.share`
/// for child records and an existing household `CKShare`; mutating the share
/// per child can cause CloudKit container-assignment crashes in Release/TestFlight.
func includeInHouseholdShare(
    persistentContainer _: NSPersistentCloudKitContainer,
    household: Household,
    objects: [NSManagedObject],
    label: String
) {
    guard !objects.isEmpty else { return }

#if DEBUG
    debugPrintStorePlacement(household: household, objects: objects, label: label)
#endif

    print("ℹ️ \(label) inherits household share via parent household relationship (no per-object share mutation)")
}

#if DEBUG
private func debugPrintStorePlacement(household: Household, objects: [NSManagedObject], label: String) {
    let householdStore = household.objectID.persistentStore?.url?.lastPathComponent ?? "unknown-store"

    print("🧩 [ShareInclusion] \(label) householdStore=\(householdStore)")

    for object in objects {
        let storeName = object.objectID.persistentStore?.url?.lastPathComponent ?? "unknown-store"
        print("🧩 [ShareInclusion] \(label) object=\(object.objectID.uriRepresentation().absoluteString) store=\(storeName)")
    }
}
#endif
