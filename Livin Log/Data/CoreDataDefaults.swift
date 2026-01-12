//
//  CoreDataDefaults.swift
//  Keeply
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
    }
}

extension HouseholdMember {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "createdAt")
    }
}

extension Movie {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "createdAt")
    }
}

extension MovieFeedback {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "updatedAt")
        // slept default: false happens automatically for non-optional Bool
    }
}

extension Viewing {
    public override nonisolated func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "id")
        setPrimitiveValue(Date(), forKey: "watchedOn")
        // isRewatch default: false happens automatically for non-optional Bool
    }
}
