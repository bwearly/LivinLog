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
    ) -> MovieFeedback {
        let req = MovieFeedback.fetchRequest()
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "movie == %@ AND member == %@", movie, member)

        if let existing = (try? context.fetch(req))?.first as? MovieFeedback {
            print("ℹ️ Reusing feedback for movie:", movie.objectID, "member:", member.objectID)
            return existing
        }

        let fb = MovieFeedback(context: context)
        fb.id = UUID()
        fb.updatedAt = Date()
        fb.rating = 0
        fb.slept = false
        fb.movie = movie
        fb.member = member
        print("✅ Created feedback for movie:", movie.objectID, "member:", member.objectID)
        return fb
    }
}
