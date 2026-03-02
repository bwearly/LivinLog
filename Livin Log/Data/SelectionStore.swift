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
    private static let deviceMemberMapKey = "selectedDeviceMemberByHouseholdURI"

    static func save(household: Household?, member: HouseholdMember?) {
        let defaults = UserDefaults.standard
        let householdURI = household?.objectID.uriRepresentation().absoluteString
        let memberURI = member?.objectID.uriRepresentation().absoluteString

        if defaults.string(forKey: householdKey) != householdURI {
            if let householdURI {
                defaults.set(householdURI, forKey: householdKey)
            } else {
                defaults.removeObject(forKey: householdKey)
            }
        }

        if defaults.string(forKey: memberKey) != memberURI {
            if let memberURI {
                defaults.set(memberURI, forKey: memberKey)
            } else {
                defaults.removeObject(forKey: memberKey)
            }
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

    static func saveDeviceMember(_ member: HouseholdMember?, for household: Household?) {
        guard let household else { return }

        let defaults = UserDefaults.standard
        var map = defaults.dictionary(forKey: deviceMemberMapKey) as? [String: String] ?? [:]
        let householdURI = household.objectID.uriRepresentation().absoluteString

        if let member {
            map[householdURI] = member.objectID.uriRepresentation().absoluteString
        } else {
            map.removeValue(forKey: householdURI)
        }

        let existingMap = defaults.dictionary(forKey: deviceMemberMapKey) as? [String: String] ?? [:]
        if existingMap != map {
            defaults.set(map, forKey: deviceMemberMapKey)
        }
    }

    static func loadDeviceMember(for household: Household, context: NSManagedObjectContext) -> HouseholdMember? {
        let defaults = UserDefaults.standard
        guard let map = defaults.dictionary(forKey: deviceMemberMapKey) as? [String: String] else {
            return nil
        }

        let householdURI = household.objectID.uriRepresentation().absoluteString
        guard let memberURI = map[householdURI],
              let url = URL(string: memberURI),
              let psc = context.persistentStoreCoordinator,
              let oid = psc.managedObjectID(forURIRepresentation: url)
        else {
            return nil
        }

        guard let member = try? context.existingObject(with: oid) as? HouseholdMember,
              member.household?.objectID == household.objectID
        else {
            return nil
        }

        return member
    }

    static func clearAll() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: householdKey)
        defaults.removeObject(forKey: memberKey)
        defaults.removeObject(forKey: deviceMemberMapKey)
    }
}
