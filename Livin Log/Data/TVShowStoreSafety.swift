import CoreData

enum TVShowStoreSafety {
    static func assignInserted(_ tvShow: TVShow, toSameStoreAs household: Household, context: NSManagedObjectContext) throws {
        try context.assign(tvShow, toSameStoreAs: household, referenceLabel: "TVShow household")
        debugLogTVShowGraph(operation: "TVShow.assignInserted", tvShow: tvShow, household: household, context: context, assignedBeforeRelationships: true)
    }

    static func graphObjects(tvShow: TVShow, context: NSManagedObjectContext) -> [(String, NSManagedObject?)] {
        var objects: [(String, NSManagedObject?)] = [
            ("tvShow", tvShow),
            ("tvShow.household", tvShow.household)
        ]

        for relationship in tvShow.entity.relationshipsByName.values.sorted(by: { $0.name < $1.name }) where relationship.name != "household" {
            if relationship.isToMany {
                let relatedObjects = (tvShow.value(forKey: relationship.name) as? NSSet)?.compactMap { $0 as? NSManagedObject } ?? []
                for (index, object) in relatedObjects.enumerated() {
                    objects.append(("tvShow.\(relationship.name)[\(index)]", object))
                }
            } else {
                objects.append(("tvShow.\(relationship.name)", tvShow.value(forKey: relationship.name) as? NSManagedObject))
            }
        }

        return objects
    }

    static func validateGraph(tvShow: TVShow, context: NSManagedObjectContext, operation: String, assignedBeforeRelationships: Bool? = nil) throws {
        let household = tvShow.household
        debugLogTVShowGraph(operation: operation, tvShow: tvShow, household: household, context: context, assignedBeforeRelationships: assignedBeforeRelationships)
        let objects = graphObjects(tvShow: tvShow, context: context)
        context.debugLogStoreSafeSave(entityName: operation, household: household, member: nil, objects: objects)
        try context.validateSamePersistentStore(objects)
    }

    static func validateActiveHouseholdIfPresent(_ activeHousehold: Household?, matchesDerivedHousehold derivedHousehold: Household?, context: NSManagedObjectContext) throws {
        guard let activeHousehold, let derivedHousehold else { return }
        try context.validateSamePersistentStore([("tvShow.household", derivedHousehold), ("activeHousehold", activeHousehold)])
    }

    static func validateDelete(tvShow: TVShow, context: NSManagedObjectContext) throws {
        try validateGraph(tvShow: tvShow, context: context, operation: "TVShow.delete")
    }

    static func diagnoseTVShowGraphs(household: Household?, context: NSManagedObjectContext, reason: String) {
        #if DEBUG
        let request = NSFetchRequest<TVShow>(entityName: "TVShow")
        request.includesPendingChanges = true
        if let household {
            request.predicate = householdScopedPredicate(household)
        }

        let shows = (try? context.fetch(request)) ?? []
        for show in shows {
            do {
                try validateGraph(tvShow: show, context: context, operation: "TVShow.diagnostic.\(reason)")
            } catch {
                print("❌ [TVShowGraphDiagnostic] reason=\(reason) title=\(show.title ?? "Untitled") objectID=\(show.objectID.uriRepresentation().absoluteString) store=\(storeDebugDescription(show.objectID.persistentStore)) error=\(error.localizedDescription)")
                debugLogTVShowGraph(operation: "TVShow.diagnostic.corrupt.\(reason)", tvShow: show, household: show.household, context: context, assignedBeforeRelationships: nil)
            }
        }
        #endif
    }

    static func debugLogTVShowGraph(operation: String, tvShow: TVShow, household: Household?, context: NSManagedObjectContext, assignedBeforeRelationships: Bool?) {
        #if DEBUG
        print("🧩 [TVShowStoreSafeSave] operation=\(operation) title=\(tvShow.title ?? "Untitled") assignedBeforeRelationships=\(assignedBeforeRelationships.map { String($0) } ?? "n/a")")
        print("🧩 [TVShowStoreSafeSave] tvShow objectID=\(tvShow.objectID.uriRepresentation().absoluteString) store=\(storeDebugDescription(tvShow.objectID.persistentStore)) isInserted=\(tvShow.isInserted)")
        if let household {
            print("🧩 [TVShowStoreSafeSave] household objectID=\(household.objectID.uriRepresentation().absoluteString) store=\(storeDebugDescription(household.objectID.persistentStore)) isInserted=\(household.isInserted)")
        } else {
            print("🧩 [TVShowStoreSafeSave] household=nil")
        }

        for relationship in tvShow.entity.relationshipsByName.values.sorted(by: { $0.name < $1.name }) {
            if relationship.isToMany {
                let relatedObjects = (tvShow.value(forKey: relationship.name) as? NSSet)?.compactMap { $0 as? NSManagedObject } ?? []
                if relatedObjects.isEmpty {
                    print("🧩 [TVShowStoreSafeSave] related \(relationship.name)=empty")
                }
                for (index, object) in relatedObjects.enumerated() {
                    print("🧩 [TVShowStoreSafeSave] related \(relationship.name)[\(index)] entity=\(object.entity.name ?? "Unknown") objectID=\(object.objectID.uriRepresentation().absoluteString) store=\(storeDebugDescription(object.objectID.persistentStore)) isInserted=\(object.isInserted)")
                }
            } else if relationship.name != "household" {
                if let object = tvShow.value(forKey: relationship.name) as? NSManagedObject {
                    print("🧩 [TVShowStoreSafeSave] related \(relationship.name) entity=\(object.entity.name ?? "Unknown") objectID=\(object.objectID.uriRepresentation().absoluteString) store=\(storeDebugDescription(object.objectID.persistentStore)) isInserted=\(object.isInserted)")
                } else {
                    print("🧩 [TVShowStoreSafeSave] related \(relationship.name)=nil")
                }
            }
        }
        #endif
    }
}
