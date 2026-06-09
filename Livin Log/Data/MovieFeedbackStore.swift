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

        let req = NSFetchRequest<MovieFeedback>(entityName: "MovieFeedback")
        req.predicate = NSPredicate(format: "movie == %@ AND member == %@", movie, member)
        let matchingFeedback = try context.fetch(req)
            .sorted(by: shouldKeepBefore)
        if let existing = matchingFeedback.first {
            let existingObjects: [(String, NSManagedObject?)] = [
                ("feedback", existing),
                ("movie", movie),
                ("member", member),
                ("household", existing.household ?? movie.household)
            ]
            try context.validateSamePersistentStore(existingObjects)
            if existing.household == nil { existing.household = movie.household }
            for duplicate in matchingFeedback.dropFirst() {
                context.delete(duplicate)
            }
            print("ℹ️ Reusing feedback for movie:", movie.objectID, "member:", member.objectID)
            return existing
        }

        let fb = MovieFeedback(context: context)
        try MovieStoreSafety.assignInserted(fb, toSameStoreAs: movie, label: "MovieFeedback.getOrCreate", context: context)
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
        try MovieStoreSafety.validateMovieGraph(movie: movie, household: movie.household, context: context, operation: "MovieFeedback.getOrCreate")
        #if DEBUG
        if let household = movie.household {
            context.debugLogStoreSafeSave(entityName: "MovieFeedback", household: household, member: member, objects: [("feedback", fb), ("movie", movie), ("member", member), ("household", household)])
        }
        #endif
        print("✅ Created feedback for movie:", movie.objectID, "member:", member.objectID)
        return fb
    }

    private static func shouldKeepBefore(_ lhs: MovieFeedback, _ rhs: MovieFeedback) -> Bool {
        let lhsUpdatedAt = lhs.updatedAt ?? .distantPast
        let rhsUpdatedAt = rhs.updatedAt ?? .distantPast
        if lhsUpdatedAt != rhsUpdatedAt {
            return lhsUpdatedAt > rhsUpdatedAt
        }
        return lhs.objectID.uriRepresentation().absoluteString < rhs.objectID.uriRepresentation().absoluteString
    }
}
