import CoreData
import CloudKit

func activeHouseholdInContext(_ household: Household, context: NSManagedObjectContext) -> Household? {
    if household.managedObjectContext == context {
        return household
    }

    return (try? context.existingObject(with: household.objectID)) as? Household
}

func householdScopedPredicate(_ household: Household) -> NSPredicate {
    return NSPredicate(format: "household == %@", household)
}

func assignIfInserted(_ obj: NSManagedObject, to store: NSPersistentStore?, in context: NSManagedObjectContext) {
    #if DEBUG
    let storeName = store?.url?.lastPathComponent ?? "nil-store"
    print("🧩 [StoreAssign] entity=\(obj.entity.name ?? "Unknown") isInserted=\(obj.isInserted) store=\(storeName)")
    #endif

    guard obj.isInserted, let store else { return }
    context.assign(obj, to: store)
}

func storeForParent(_ parent: NSManagedObject) -> NSPersistentStore? {
    parent.objectID.persistentStore
}

enum StoreValidationError: LocalizedError {
    case missingReferenceStore(String)
    case unresolvedObjectStore(String)
    case crossStoreRelationship(String)

    var errorDescription: String? {
        switch self {
        case .missingReferenceStore(let label):
            return "Could not determine the persistent store for \(label). Please try again after the household finishes syncing."
        case .unresolvedObjectStore(let label):
            return "Could not determine the persistent store for \(label). Please try again before saving."
        case .crossStoreRelationship(let details):
            return "This save would link records across private and shared stores (\(details)). Nothing was saved."
        }
    }
}

extension NSManagedObjectContext {
    func assign(_ object: NSManagedObject, toSameStoreAs reference: NSManagedObject, referenceLabel: String = "reference") throws {
        guard let store = reference.objectID.persistentStore else {
            throw StoreValidationError.missingReferenceStore(referenceLabel)
        }
        if object.isInserted {
            assign(object, to: store)
        }
    }

    func validateSamePersistentStore(_ labeledObjects: [(String, NSManagedObject?)]) throws {
        var expectedStore: NSPersistentStore?
        var expectedLabel: String?

        for (label, object) in labeledObjects {
            guard let object else { continue }
            guard let store = object.objectID.persistentStore else {
                throw StoreValidationError.unresolvedObjectStore(label)
            }
            if let expectedStore, store !== expectedStore {
                let lhs = "\(expectedLabel ?? "first object")=\(storeDebugDescription(expectedStore))"
                let rhs = "\(label)=\(storeDebugDescription(store))"
                throw StoreValidationError.crossStoreRelationship("\(lhs), \(rhs)")
            }
            expectedStore = store
            expectedLabel = label
        }
    }

    func debugLogStoreSafeSave(entityName: String, household: Household?, member: HouseholdMember?, objects: [(String, NSManagedObject?)]) {
        #if DEBUG
        let householdName = household?.name ?? "<nil>"
        let householdID = household?.id?.uuidString ?? "<nil>"
        let memberName = member?.displayName ?? "<nil>"
        let memberID = member?.id?.uuidString ?? "<nil>"
        print("🧩 [StoreSafeSave] entity=\(entityName) household=\(householdName) id=\(householdID) member=\(memberName) id=\(memberID)")
        for (label, object) in objects {
            guard let object else {
                print("🧩 [StoreSafeSave] \(label)=nil")
                continue
            }
            print("🧩 [StoreSafeSave] \(label) entity=\(object.entity.name ?? "Unknown") objectID=\(object.objectID.uriRepresentation().absoluteString) store=\(storeDebugDescription(object.objectID.persistentStore)) isInserted=\(object.isInserted) assignCalled=see-prior-StoreAssign-or-MovieStoreAssign-log")
        }
        #endif
    }
}

func storeDebugDescription(_ store: NSPersistentStore?) -> String {
    guard let store else { return "nil-store" }
    let url = store.url?.absoluteString ?? "<no-url>"
    let scope: String
    if url.contains("-shared") {
        scope = "shared"
    } else if url.contains("LivinLog.sqlite") {
        scope = "private"
    } else {
        scope = "unknown"
    }
    return "\(url) scope=\(scope)"
}

#if DEBUG
func debugStoreName(for objectID: NSManagedObjectID, context: NSManagedObjectContext) -> String {
    let store = objectID.persistentStore
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

    let entities = ["LLQuote", "LLPuzzle", "LLCalendarEvent", "LLChild", "Movie", "TVShow", "BookEntry"]
    for entity in entities {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        req.predicate = householdScopedPredicate(scopedHousehold)
        req.includesPendingChanges = true
        let count = (try? context.count(for: req)) ?? -1
        print("🧪 [SyncDiag] \(entity) count=\(count)")
    }
}
#endif


#if DEBUG
func debugPrintShareStatus(for household: Household, persistentContainer: NSPersistentCloudKitContainer) {
    do {
        let shares = try persistentContainer.fetchShares(matching: [household.objectID])
        if let share = shares[household.objectID] {
            let urlText = share.url?.absoluteString ?? "nil"
            print("🧪 [SyncDiag] householdShare=exists recordID=\(share.recordID.recordName) url=\(urlText)")
        } else {
            print("🧪 [SyncDiag] householdShare=missing")
        }
    } catch {
        print("🧪 [SyncDiag] householdShare=error error=\(error.localizedDescription)")
    }
}
#endif
