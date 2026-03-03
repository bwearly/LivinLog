import CoreData

func activeHouseholdInContext(_ household: Household, context: NSManagedObjectContext) -> Household? {
    if household.managedObjectContext == context {
        return household
    }

    return (try? context.existingObject(with: household.objectID)) as? Household
}

func householdScopedPredicate(_ household: Household) -> NSPredicate {
    NSPredicate(format: "household == %@", household)
}

#if DEBUG
func debugPrintStore(entityName: String, objectID: NSManagedObjectID, context: NSManagedObjectContext) {
    let store = context.persistentStoreCoordinator?.persistentStore(for: objectID)
    let storeURL = store?.url?.lastPathComponent ?? "unknown-store"
    print("🧩 [StoreDebug] \(entityName) objectID=\(objectID.uriRepresentation().absoluteString) store=\(storeURL)")
}

func debugLogHouseholdAssignment(entityName: String, object: NSManagedObject, household: Household, context: NSManagedObjectContext) {
    debugPrintStore(entityName: "Household(active)", objectID: household.objectID, context: context)
    debugPrintStore(entityName: entityName, objectID: object.objectID, context: context)

    let linkedHousehold = object.value(forKey: "household") as? Household
    let relationshipMatch = (linkedHousehold?.objectID == household.objectID)
    print("🧩 [StoreDebug] \(entityName) householdMatch=\(relationshipMatch) householdName=\(household.name ?? "nil")")

    if object.entity.attributesByName.keys.contains("householdID") {
        let objHouseholdID = object.value(forKey: "householdID") as? UUID
        print("🧩 [StoreDebug] \(entityName) householdID object=\(objHouseholdID?.uuidString ?? "nil") active=\(household.id?.uuidString ?? "nil")")
    }
}
#endif
