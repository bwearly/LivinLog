import CoreData

enum MovieStoreSafety {
    static func persistentStore(for object: NSManagedObject?, label: String) throws -> NSPersistentStore {
        guard let object else { throw StoreValidationError.unresolvedObjectStore(label) }
        guard let store = object.objectID.persistentStore else { throw StoreValidationError.unresolvedObjectStore(label) }
        return store
    }

    @discardableResult
    static func assignInserted(_ object: NSManagedObject, toSameStoreAs reference: NSManagedObject, label: String, context: NSManagedObjectContext) throws -> Bool {
        let store = try persistentStore(for: reference, label: "reference for \(label)")
        let didAssign = object.isInserted
        if didAssign {
            context.assign(object, to: store)
        }
        #if DEBUG
        print("🧩 [MovieStoreAssign] \(label) objectID=\(object.objectID.uriRepresentation().absoluteString) isInserted=\(object.isInserted) assignCalled=\(didAssign) store=\(storeDebugDescription(store))")
        #endif
        return didAssign
    }


    static func resolveMember(_ candidate: HouseholdMember?, in household: Household, context: NSManagedObjectContext) throws -> HouseholdMember? {
        guard let candidate else { return nil }
        guard let store = household.objectID.persistentStore else {
            throw StoreValidationError.unresolvedObjectStore("household")
        }

        if candidate.managedObjectContext == context,
           candidate.objectID.persistentStore === store,
           candidate.household?.objectID == household.objectID {
            return candidate
        }

        if let candidateInContext = try? context.existingObject(with: candidate.objectID) as? HouseholdMember,
           candidateInContext.objectID.persistentStore === store,
           candidateInContext.household?.objectID == household.objectID {
            return candidateInContext
        }

        guard let memberID = candidate.id else {
            throw StoreValidationError.unresolvedObjectStore("selected member id")
        }

        let request = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        request.fetchLimit = 1
        request.affectedStores = [store]
        request.predicate = NSPredicate(format: "id == %@ AND household == %@", argumentArray: [memberID, household])

        guard let resolved = try context.fetch(request).first else {
            throw StoreValidationError.crossStoreRelationship("selectedMember=\(storeDebugDescription(candidate.objectID.persistentStore)), householdStore=\(storeDebugDescription(store)); no store-scoped member match")
        }

        return resolved
    }

    static func validateViewingGraph(viewing: Viewing, movie: Movie?, household: Household?, member: HouseholdMember?, context: NSManagedObjectContext, operation: String, assignedBeforeRelationships: Bool) throws {
        let objects: [(String, NSManagedObject?)] = [
            ("viewing", viewing),
            ("movie", movie),
            ("household", household),
            ("member", member)
        ]
        context.debugLogViewingSave(operation: operation, viewing: viewing, movie: movie, household: household, member: member, assignedBeforeRelationships: assignedBeforeRelationships)
        try context.validateSamePersistentStore(objects)
        if let movie {
            try validateMovieGraph(movie: movie, household: household, context: context, operation: operation)
        }
    }

    static func fetchViewings(for movie: Movie, context: NSManagedObjectContext) throws -> [Viewing] {
        let request = NSFetchRequest<Viewing>(entityName: "Viewing")
        request.predicate = NSPredicate(format: "movie == %@", movie)
        request.includesPendingChanges = true
        return try context.fetch(request)
    }

    static func fetchFeedbacks(for movie: Movie, context: NSManagedObjectContext) throws -> [MovieFeedback] {
        let request = NSFetchRequest<MovieFeedback>(entityName: "MovieFeedback")
        request.predicate = NSPredicate(format: "movie == %@", movie)
        request.includesPendingChanges = true
        return try context.fetch(request)
    }

    static func graphObjects(movie: Movie, household: Household?, context: NSManagedObjectContext) throws -> [(String, NSManagedObject?)] {
        var objects: [(String, NSManagedObject?)] = [
            ("movie", movie),
            ("movie.household", movie.household),
            ("activeHousehold", household)
        ]

        let relatedViewings: [Viewing]
        if movie.isInserted, let pendingViewings = movie.value(forKey: "viewing") as? NSSet {
            relatedViewings = pendingViewings.compactMap { $0 as? Viewing }
        } else {
            relatedViewings = try fetchViewings(for: movie, context: context)
        }

        for (index, viewing) in relatedViewings.enumerated() {
            objects.append(("viewing[\(index)]", viewing))
            objects.append(("viewing[\(index)].household", viewing.household))
            objects.append(("viewing[\(index)].movie", viewing.movie))
        }

        let relatedFeedbacks: [MovieFeedback]
        if movie.isInserted, let pendingFeedbacks = movie.value(forKey: "feedbacks") as? NSSet {
            relatedFeedbacks = pendingFeedbacks.compactMap { $0 as? MovieFeedback }
        } else {
            relatedFeedbacks = try fetchFeedbacks(for: movie, context: context)
        }

        for (index, feedback) in relatedFeedbacks.enumerated() {
            objects.append(("feedback[\(index)]", feedback))
            objects.append(("feedback[\(index)].household", feedback.household))
            objects.append(("feedback[\(index)].movie", feedback.movie))
            objects.append(("feedback[\(index)].member", feedback.member))
        }


        return objects
    }

    static func validateMovieGraph(movie: Movie, household: Household?, context: NSManagedObjectContext, operation: String) throws {
        let objects = try graphObjects(movie: movie, household: household, context: context)
        context.debugLogStoreSafeSave(entityName: operation, household: household ?? movie.household, member: nil, objects: objects)
        try context.validateSamePersistentStore(objects)
    }

    static func validateMovieDelete(movie: Movie, context: NSManagedObjectContext) throws {
        try validateMovieGraph(movie: movie, household: movie.household, context: context, operation: "Movie.delete")
    }

    static func validateHouseholdMovieGraphs(household: Household, context: NSManagedObjectContext, operation: String) throws {
        let request = NSFetchRequest<Movie>(entityName: "Movie")
        request.predicate = householdScopedPredicate(household)
        request.includesPendingChanges = true
        for movie in try context.fetch(request) {
            try validateMovieGraph(movie: movie, household: household, context: context, operation: operation)
        }
    }

    #if DEBUG
    static func diagnoseMovieGraphs(household: Household, context: NSManagedObjectContext, reason: String) {
        let request = NSFetchRequest<Movie>(entityName: "Movie")
        request.predicate = householdScopedPredicate(household)
        request.includesPendingChanges = true
        let movies = (try? context.fetch(request)) ?? []
        for movie in movies {
            do {
                try validateMovieGraph(movie: movie, household: household, context: context, operation: "Movie.diagnostic.\(reason)")
            } catch {
                let title = movie.title ?? "Untitled"
                print("❌ [MovieGraphDiagnostic] title=\(title) objectID=\(movie.objectID.uriRepresentation().absoluteString) error=\(error.localizedDescription)")
                if let viewings = try? fetchViewings(for: movie, context: context) {
                    for viewing in viewings {
                        print("❌ [MovieGraphDiagnostic] viewing objectID=\(viewing.objectID.uriRepresentation().absoluteString) store=\(storeDebugDescription(viewing.objectID.persistentStore)) householdStore=\(storeDebugDescription(viewing.household?.objectID.persistentStore))")
                    }
                }
                if let feedbacks = try? fetchFeedbacks(for: movie, context: context) {
                    for feedback in feedbacks {
                        print("❌ [MovieGraphDiagnostic] feedback objectID=\(feedback.objectID.uriRepresentation().absoluteString) store=\(storeDebugDescription(feedback.objectID.persistentStore)) householdStore=\(storeDebugDescription(feedback.household?.objectID.persistentStore)) memberStore=\(storeDebugDescription(feedback.member?.objectID.persistentStore))")
                    }
                }
            }
        }
    }
    #endif
}
