import CoreData

func activeHouseholdInContext(_ household: Household, context: NSManagedObjectContext) -> Household? {
    if household.managedObjectContext == context {
        return household
    }

    return (try? context.existingObject(with: household.objectID)) as? Household
}

func householdScopedPredicate(_ household: Household) -> NSPredicate {
    return NSPredicate(format: "household == %@", household)
}

#if DEBUG
func debugStoreName(for objectID: NSManagedObjectID, context: NSManagedObjectContext) -> String {
    let store = context.persistentStoreCoordinator?.persistentStore(for: objectID)
    return store?.url?.lastPathComponent ?? "unknown-store"
}

func debugPrintStore(entityName: String, objectID: NSManagedObjectID, context: NSManagedObjectContext) {
    let storeURL = debugStoreName(for: objectID, context: context)
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

func debugPrintHouseholdDiagnostics(household: Household, context: NSManagedObjectContext, reason: String) {
    guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
        print("🧪 [SyncDiag] Could not scope household for diagnostics [\(reason)]")
        return
    }

    let householdStore = debugStoreName(for: scopedHousehold.objectID, context: context)
    print("🧪 [SyncDiag] household=\(scopedHousehold.name ?? "Unnamed") id=\(scopedHousehold.objectID.uriRepresentation().absoluteString) store=\(householdStore) [\(reason)]")

    let entities = ["LLQuote", "LLPuzzle", "LLCalendarEvent", "LLChild", "Movie", "TVShow"]
    for entity in entities {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        req.predicate = householdScopedPredicate(scopedHousehold)
        req.includesPendingChanges = true
        let count = (try? context.count(for: req)) ?? -1
        print("🧪 [SyncDiag] \(entity) count=\(count)")
    }
}
#endif
