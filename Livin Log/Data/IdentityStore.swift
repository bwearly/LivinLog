import Foundation
import CoreData

enum IdentityStore {
    static let providerApple = "apple"

    static func durableUserId(provider: String, subject: String) -> String {
        "\(provider):\(subject)"
    }

    static func durableUserId(for appUser: AppUser) -> String? {
        guard let provider = appUser.authProvider, let subject = appUser.providerSubject else { return nil }
        return durableUserId(provider: provider, subject: subject)
    }

    static func fetchOrCreateAppUser(
        provider: String,
        subject: String,
        displayName: String?,
        context: NSManagedObjectContext,
        in store: NSPersistentStore? = nil
    ) throws -> AppUser {
        let req = NSFetchRequest<AppUser>(entityName: "AppUser")
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "authProvider == %@ AND providerSubject == %@", provider, subject)
        if let store { req.affectedStores = [store] }

        if let existing = try context.fetch(req).first {
            var changed = false
            if let displayName, !displayName.isEmpty, (existing.displayName ?? "").isEmpty {
                existing.displayName = displayName
                changed = true
            }
            existing.setValue(Date(), forKey: "lastSeenAt")
            changed = true
            if changed { try context.save() }
            debug("resolved AppUser provider=\(provider) subjectHash=\(subject.hashValue) store=\(storeLabel(existing))")
            return existing
        }

        let user = AppUser(context: context)
        if let store { context.assign(user, to: store) }
        user.id = UUID()
        user.authProvider = provider
        user.providerSubject = subject
        user.displayName = displayName
        user.createdAt = Date()
        user.setValue(Date(), forKey: "lastSeenAt")
        try context.save()
        debug("created AppUser provider=\(provider) subjectHash=\(subject.hashValue) store=\(storeLabel(user))")
        return user
    }

    static func storeScopedAppUser(matching actor: AppUser, household: Household, context: NSManagedObjectContext) throws -> AppUser {
        guard let provider = actor.authProvider, let subject = actor.providerSubject else {
            throw NSError(domain: "IdentityStore", code: 10, userInfo: [NSLocalizedDescriptionKey: "Current user identity is incomplete."])
        }
        return try fetchOrCreateAppUser(provider: provider, subject: subject, displayName: actor.displayName, context: context, in: household.objectID.persistentStore)
    }

    static func memberships(for appUser: AppUser, context: NSManagedObjectContext) -> [HouseholdMembership] {
        guard let subject = appUser.providerSubject else { return [] }
        let req = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
        req.predicate = NSPredicate(format: "status == %@ AND (appUser.providerSubject == %@ OR appUserId == %@)", "active", subject, durableUserId(for: appUser) ?? subject)
        req.sortDescriptors = [NSSortDescriptor(key: "joinedAt", ascending: true), NSSortDescriptor(key: "createdAt", ascending: true)]
        let memberships = (try? context.fetch(req)) ?? []
        memberships.forEach { backfillMembershipIfPossible($0) }
        if context.hasChanges { try? context.save() }
        debug("memberships resolved count=\(memberships.count) subjectHash=\(subject.hashValue)")
        return memberships
    }

    static func membership(
        for appUser: AppUser,
        household: Household,
        member: HouseholdMember,
        context: NSManagedObjectContext
    ) -> HouseholdMembership? {
        guard let subject = appUser.providerSubject else { return nil }
        let durableId = durableUserId(for: appUser) ?? subject
        let req = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
        req.fetchLimit = 1
        req.predicate = NSPredicate(
            format: "household == %@ AND memberProfile == %@ AND status == %@ AND (appUser.providerSubject == %@ OR appUserId == %@)",
            household,
            member,
            "active",
            subject,
            durableId
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
        let scopedUser = try storeScopedAppUser(matching: appUser, household: household, context: context)
        guard let durableId = durableUserId(for: scopedUser), let householdId = household.id, let memberId = member.id else {
            throw NSError(domain: "IdentityStore", code: 11, userInfo: [NSLocalizedDescriptionKey: "Household, member, or user identifiers are missing."])
        }

        if let existing = membership(for: scopedUser, household: household, member: member, context: context) {
            backfillMembership(existing, appUserId: durableId, householdId: householdId, memberId: memberId)
            member.setValue(durableId, forKey: "claimedByAppUserId")
            if context.hasChanges { try context.save() }
            return existing
        }

        let duplicateReq = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
        duplicateReq.fetchLimit = 1
        duplicateReq.predicate = NSPredicate(format: "household == %@ AND memberProfile == %@ AND status == %@", household, member, "active")

        if let existingOwner = try context.fetch(duplicateReq).first {
            let existingId = existingOwner.value(forKey: "appUserId") as? String ?? durableUserId(for: existingOwner.appUser ?? scopedUser)
            if existingId != durableId {
                throw NSError(domain: "IdentityStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "That member profile is already claimed."])
            }
            backfillMembership(existingOwner, appUserId: durableId, householdId: householdId, memberId: memberId)
            existingOwner.appUser = scopedUser
            member.setValue(durableId, forKey: "claimedByAppUserId")
            try context.save()
            return existingOwner
        }

        let membership = HouseholdMembership(context: context)
        if let store = household.objectID.persistentStore { context.assign(membership, to: store) }
        membership.id = UUID()
        membership.createdAt = Date()
        membership.setValue(Date(), forKey: "joinedAt")
        membership.status = "active"
        membership.role = role
        membership.appUser = scopedUser
        membership.household = household
        membership.memberProfile = member
        backfillMembership(membership, appUserId: durableId, householdId: householdId, memberId: memberId)
        member.setValue(durableId, forKey: "claimedByAppUserId")
        try context.save()
        debug("created membership role=\(role) userId=\(durableId) household=\(household.name ?? "Household") member=\(member.displayName ?? "Member") store=\(storeLabel(membership))")
        return membership
    }

    static func unclaimedMembers(for household: Household, context: NSManagedObjectContext) -> [HouseholdMember] {
        let membersReq = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        membersReq.predicate = NSPredicate(format: "household == %@", household)
        membersReq.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let members = (try? context.fetch(membersReq)) ?? []

        return members.filter { member in
            if let claimed = member.value(forKey: "claimedByAppUserId") as? String, !claimed.isEmpty { return false }
            let req = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
            req.fetchLimit = 1
            req.predicate = NSPredicate(format: "memberProfile == %@ AND status == %@", member, "active")
            return ((try? context.fetch(req))?.isEmpty ?? true)
        }
    }

    static func canAct(as member: HouseholdMember?, appUser: AppUser?, context: NSManagedObjectContext) -> Bool {
        guard let member, let appUser, let household = member.household else { return false }
        if let claimed = member.value(forKey: "claimedByAppUserId") as? String,
           let durableId = durableUserId(for: appUser),
           !claimed.isEmpty,
           claimed != durableId {
            debug("book/member authorization denied claimedBy mismatch")
            return false
        }
        let allowed = membership(for: appUser, household: household, member: member, context: context) != nil
        debug("authorization canAct=\(allowed) household=\(household.name ?? "Household") member=\(member.displayName ?? "Member")")
        return allowed
    }

    static func backfillMembershipIfPossible(_ membership: HouseholdMembership) {
        guard let household = membership.household,
              let member = membership.memberProfile,
              let appUser = membership.appUser,
              let appUserId = durableUserId(for: appUser),
              let householdId = household.id,
              let memberId = member.id else { return }

        backfillMembership(membership, appUserId: appUserId, householdId: householdId, memberId: memberId)
        if (member.value(forKey: "claimedByAppUserId") as? String)?.isEmpty != false {
            member.setValue(appUserId, forKey: "claimedByAppUserId")
        }
    }

    private static func backfillMembership(_ membership: HouseholdMembership, appUserId: String, householdId: UUID, memberId: UUID) {
        membership.setValue(appUserId, forKey: "appUserId")
        membership.setValue(householdId, forKey: "householdId")
        membership.setValue(memberId, forKey: "householdMemberId")
        if membership.value(forKey: "joinedAt") == nil {
            membership.setValue(membership.createdAt ?? Date(), forKey: "joinedAt")
        }
    }

    private static func storeLabel(_ object: NSManagedObject) -> String {
        object.objectID.persistentStore?.url?.lastPathComponent ?? "unknown-store"
    }

    private static func debug(_ message: String) {
        #if DEBUG
        print("🪪 [Identity] \(message)")
        #endif
    }
}
