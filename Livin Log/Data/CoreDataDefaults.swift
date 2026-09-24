//
//  CoreDataDefaults.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import Foundation
import CoreData

extension Household {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "createdAt")
        // Phase 1 (CKSyncEngine migration): stable CloudKit record name, stamped once at
        // insert so cross-entity links (Movie.household, MovieFeedback.household, etc.) have
        // a stable target to reference before the first sync send.
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

extension HouseholdMember {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "createdAt")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

extension Movie {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "createdAt")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

extension MovieFeedback {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "updatedAt")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
        // slept default: false happens automatically for non-optional Bool
    }
}

extension TVShow {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "createdAt")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

extension Viewing {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "watchedOn")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
        // isRewatch default: false happens automatically for non-optional Bool
    }
}


// Phase 4a (Batch 2): stable CloudKit record name stamped at insert, like Movie. `id` is
// stamped too so every synced row has one to round-trip (callers that set their own `id`
// after insert, e.g. AddEditQuoteView's `if quote.id == nil`, are unaffected).
extension LLQuote {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

extension LLPuzzle {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

extension LLCalendarEvent {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

// Phase 4a (Batch 3): stable CloudKit record name (and id) stamped at insert, like Movie.
// RecipeStore's own `x.id = UUID()` after insert is unaffected.
extension Recipe {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

extension RecipeCategory {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

extension RecipeIngredient {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

extension RecipeStep {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

extension RecipePhoto {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}

extension AppUser {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        let now = Date()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(now, forKey: "createdAt")
        setPrimitiveValue(now, forKey: "lastSeenAt")
    }
}

extension HouseholdMembership {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        let now = Date()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(now, forKey: "createdAt")
        setPrimitiveValue(now, forKey: "joinedAt")
        setPrimitiveValue("active", forKey: "status")
        setPrimitiveValue("member", forKey: "role")
    }
}

extension BookEntry {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "createdAt")
        setPrimitiveValue(UUID().uuidString, forKey: "recordName")
    }
}


extension Invite {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "createdAt")
        setPrimitiveValue("active", forKey: "status")
    }
}
