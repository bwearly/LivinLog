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
