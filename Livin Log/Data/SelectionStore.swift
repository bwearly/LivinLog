//
//  SelectionStore.swift
//  Livin Log
//
//  Created by Blake Early on 1/6/26.
//


import Foundation
import CoreData

enum SelectionStore {
    private static let householdKey = "selectedHouseholdURI"
    private static let memberKey = "selectedMemberURI"

    static func save(household: Household?, member: HouseholdMember?) {
        let defaults = UserDefaults.standard

        if let household {
            defaults.set(household.objectID.uriRepresentation().absoluteString, forKey: householdKey)
        } else {
            defaults.removeObject(forKey: householdKey)
        }

        if let member {
            defaults.set(member.objectID.uriRepresentation().absoluteString, forKey: memberKey)
        } else {
            defaults.removeObject(forKey: memberKey)
        }
    }

    static func load(context: NSManagedObjectContext) -> (Household?, HouseholdMember?) {
        let defaults = UserDefaults.standard

        func objectID(from key: String) -> NSManagedObjectID? {
            guard let str = defaults.string(forKey: key),
                  let url = URL(string: str),
                  let psc = context.persistentStoreCoordinator,
                  let oid = psc.managedObjectID(forURIRepresentation: url)
            else { return nil }
            return oid
        }

        var household: Household?
        var member: HouseholdMember?

        if let hid = objectID(from: householdKey) {
            household = try? context.existingObject(with: hid) as? Household
        }
        if let mid = objectID(from: memberKey) {
            member = try? context.existingObject(with: mid) as? HouseholdMember
        }

        return (household, member)
    }
}
