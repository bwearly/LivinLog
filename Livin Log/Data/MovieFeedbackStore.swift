//
//  MovieFeedbackStore.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//


import CoreData

enum MovieFeedbackStore {
    static func getOrCreate(
        movie: Movie,
        member: HouseholdMember,
        context: NSManagedObjectContext
    ) throws -> MovieFeedback {
        let relatedObjects: [(String, NSManagedObject?)] = [
            ("movie", movie),
            ("member", member),
            ("household", movie.household)
        ]
        try context.validateSamePersistentStore(relatedObjects)

        let req = MovieFeedback.fetchRequest()
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "movie == %@ AND member == %@", movie, member)
        if let store = movie.objectID.persistentStore { req.affectedStores = [store] }

        if let existing = (try? context.fetch(req))?.first as? MovieFeedback {
            let existingObjects: [(String, NSManagedObject?)] = [
                ("feedback", existing),
                ("movie", movie),
                ("member", member),
                ("household", existing.household ?? movie.household)
            ]
            try context.validateSamePersistentStore(existingObjects)
            if existing.household == nil { existing.household = movie.household }
            print("ℹ️ Reusing feedback for movie:", movie.objectID, "member:", member.objectID)
            return existing
        }

        let fb = MovieFeedback(context: context)
        try context.assign(fb, toSameStoreAs: movie, referenceLabel: "movie")
        fb.id = UUID()
        fb.updatedAt = Date()
        fb.rating = 0
        fb.slept = false
        fb.movie = movie
        fb.member = member
        fb.household = movie.household
        try context.validateSamePersistentStore([
            ("feedback", fb),
            ("movie", movie),
            ("member", member),
            ("household", movie.household)
        ])
        #if DEBUG
        if let household = movie.household {
            context.debugLogStoreSafeSave(entityName: "MovieFeedback", household: household, member: member, objects: [("feedback", fb), ("movie", movie), ("member", member), ("household", household)])
        }
        #endif
        print("✅ Created feedback for movie:", movie.objectID, "member:", member.objectID)
        return fb
    }
}
