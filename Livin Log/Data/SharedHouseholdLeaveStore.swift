import Foundation
import CoreData

enum SharedHouseholdLeaveStore {
    private static let key = "ll_left_shared_household_uris"

    static func markLeft(_ household: Household) {
        let uri = household.objectID.uriRepresentation().absoluteString
        var values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        values.insert(uri)
        UserDefaults.standard.set(Array(values), forKey: key)
#if DEBUG
        print("🧹 [ProfileCleanup] marked shared household left uri=\(uri)")
#endif
    }

    static func contains(_ household: Household) -> Bool {
        let uri = household.objectID.uriRepresentation().absoluteString
        return Set(UserDefaults.standard.stringArray(forKey: key) ?? []).contains(uri)
    }

    static func contains(_ membership: HouseholdMembership) -> Bool {
        guard let household = membership.household else { return false }
        return contains(household)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
