import Foundation
import CoreData

enum IdentityStore {
    static let providerApple = "apple"

    static func fetchOrCreateAppUser(
        provider: String,
        subject: String,
        displayName: String?,
        context: NSManagedObjectContext
    ) throws -> AppUser {
        let req = NSFetchRequest<AppUser>(entityName: "AppUser")
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "authProvider == %@ AND providerSubject == %@", provider, subject)

        if let existing = try context.fetch(req).first {
            if let displayName, !displayName.isEmpty, (existing.displayName ?? "").isEmpty {
                existing.displayName = displayName
                try context.save()
            }
            return existing
        }

        let user = AppUser(context: context)
        user.id = UUID()
        user.authProvider = provider
        user.providerSubject = subject
        user.displayName = displayName
        user.createdAt = Date()
        try context.save()
        return user
    }

    static func memberships(for appUser: AppUser, context: NSManagedObjectContext) -> [HouseholdMembership] {
        let req = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
        req.predicate = NSPredicate(format: "appUser == %@ AND status == %@", appUser, "active")
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return (try? context.fetch(req)) ?? []
    }

    static func membership(
        for appUser: AppUser,
        household: Household,
        member: HouseholdMember,
        context: NSManagedObjectContext
    ) -> HouseholdMembership? {
        let req = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
        req.fetchLimit = 1
        req.predicate = NSPredicate(
            format: "appUser == %@ AND household == %@ AND memberProfile == %@ AND status == %@",
            appUser,
            household,
            member,
            "active"
        )
        return try? context.fetch(req).first
    }

    static func ensureMembership(
        appUser: AppUser,
        household: Household,
        member: HouseholdMember,
        role: String,
        context: NSManagedObjectContext
    ) throws -> HouseholdMembership {
        if let existing = membership(for: appUser, household: household, member: member, context: context) {
            return existing
        }

        let duplicateReq = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
        duplicateReq.fetchLimit = 1
        duplicateReq.predicate = NSPredicate(format: "household == %@ AND memberProfile == %@ AND status == %@", household, member, "active")

        if let existingOwner = try context.fetch(duplicateReq).first,
           existingOwner.appUser?.objectID != appUser.objectID {
            throw NSError(domain: "IdentityStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "That member profile is already claimed."])
        }

        let membership = HouseholdMembership(context: context)
        membership.id = UUID()
        membership.createdAt = Date()
        membership.status = "active"
        membership.role = role
        membership.appUser = appUser
        membership.household = household
        membership.memberProfile = member
        try context.save()
        return membership
    }

    static func unclaimedMembers(for household: Household, context: NSManagedObjectContext) -> [HouseholdMember] {
        let membersReq = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        membersReq.predicate = NSPredicate(format: "household == %@", household)
        membersReq.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let members = (try? context.fetch(membersReq)) ?? []

        return members.filter { member in
            let req = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
            req.fetchLimit = 1
            req.predicate = NSPredicate(format: "memberProfile == %@ AND status == %@", member, "active")
            return ((try? context.fetch(req))?.isEmpty ?? true)
        }
    }

    static func canAct(as member: HouseholdMember?, appUser: AppUser?, context: NSManagedObjectContext) -> Bool {
        guard let member, let appUser else { return false }
        guard let household = member.household else { return false }

        return membership(for: appUser, household: household, member: member, context: context) != nil
    }
}
