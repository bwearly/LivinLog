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
            if let store, existing.objectID.persistentStore !== store {
                throw StoreValidationError.crossStoreRelationship("AppUser=\(storeDebugDescription(existing.objectID.persistentStore)), requested=\(storeDebugDescription(store))")
            }
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


    static func activeMembership(
        for appUser: AppUser,
        household: Household,
        context: NSManagedObjectContext
    ) -> HouseholdMembership? {
        guard let subject = appUser.providerSubject else { return nil }
        let durableId = durableUserId(for: appUser) ?? subject
        let req = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
        req.fetchLimit = 1
        req.predicate = NSPredicate(
            format: "household == %@ AND status == %@ AND (appUser.providerSubject == %@ OR appUserId == %@)",
            household,
            "active",
            subject,
            durableId
        )
        req.sortDescriptors = [NSSortDescriptor(key: "joinedAt", ascending: true), NSSortDescriptor(key: "createdAt", ascending: true)]
        return try? context.fetch(req).first
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


    /// Shared by both flows a member can leave a household through: the leader removing
    /// someone else, and a member removing themselves. Soft-deactivates instead of detaching:
    /// `household`, `feedbacks`, `bookEntries`, and `memberships` relationships on `member` are
    /// left completely intact, and the `HouseholdMembership` row is kept (not deleted) — only
    /// `isActive` and the membership's `status` change. That keeps the relationship graph
    /// unbroken so historical attribution (e.g. past movie ratings, book entries) still
    /// resolves through `feedback.member`/`bookEntry.ownerMember` after departure, instead of
    /// silently dropping out of roster-scoped fetches the way the previous
    /// household/claimedByAppUserId-nilling implementation did.
    ///
    /// `claimedByAppUserId` is deliberately left untouched: it's this member's durable identity
    /// link, not a "currently active" flag, and clearing it would make `unclaimedMembers(for:)`
    /// offer this profile up to be claimed by someone else even though it still represents a
    /// specific person's history.
    ///
    /// This only touches Core Data. CKShare-side access revocation (removing the departing
    /// person as a CloudKit participant) is a separate step the caller is responsible for —
    /// see `CloudSharing.leaveShare` for self-leave, and the native share-management sheet for
    /// leader-initiated removal — since which mechanism applies depends on which side (owner vs.
    /// participant) is departing, and this function doesn't know that.
    ///
    /// Uses a single `"removed"` status for both leader-initiated and self-initiated departure
    /// (judgment call: a distinct `"left"` status was considered, but every existing status
    /// check in this codebase already just tests `status == "active"`, so a second inactive
    /// value would add a schema-adjacent distinction nothing currently reads).
    static func departHousehold(_ member: HouseholdMember, context: NSManagedObjectContext) throws {
        guard let household = member.household else { return }

        let membershipReq = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
        membershipReq.predicate = NSPredicate(format: "household == %@ AND memberProfile == %@ AND status == %@", household, member, "active")
        let memberships = try context.fetch(membershipReq)

        for membership in memberships {
            membership.status = "removed"
        }

        member.setValue(false, forKey: "isActive")

        if context.hasChanges { try context.save() }
        debug("member departed household (soft, data preserved) member=\(member.displayName ?? "Member") household=\(household.name ?? "Household") memberships=\(memberships.count)")
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

    /// Phase 3a authorization rule, based purely on `member`'s own data -- no `AppUser`/
    /// `HouseholdMembership` lookup, no device-local state. Allowed if the member is linked to
    /// the signed-in iCloud user, or if the member has no linked user at all (a no-phone member
    /// anyone in the household can act on behalf of). Denied only when the member is linked to a
    /// *different* account than the one currently signed in.
    static func canAct(as member: HouseholdMember?, currentUserRecordName: String?) -> Bool {
        guard let member else { return false }
        guard let linked = member.value(forKey: "linkedUserRecordName") as? String, !linked.isEmpty else {
            return true
        }
        let allowed = linked == currentUserRecordName
        debug("authorization canAct=\(allowed) member=\(member.displayName ?? "Member") linked=\(!linked.isEmpty)")
        return allowed
    }

    /// The `HouseholdMember` rows this iCloud user is the linked owner of, across every
    /// household synced to this device. Drives `AppState.start()`'s Phase 3a routing: 0 rows ->
    /// onboarding, 1 -> that household, >1 -> a picker.
    static func members(linkedTo userRecordName: String, context: NSManagedObjectContext) -> [HouseholdMember] {
        let request = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        request.predicate = NSPredicate(format: "linkedUserRecordName == %@", userRecordName)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// Phase 3b joiner flow ("Which one are you?"): active members of `household` with no
    /// linked iCloud user yet, `hasOwnIPhone` members first per the Phase 3b plan.
    static func membersAwaitingLink(in household: Household, context: NSManagedObjectContext) -> [HouseholdMember] {
        let request = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "household == %@", household),
            NSPredicate(format: "isActive == YES"),
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "linkedUserRecordName == nil"),
                NSPredicate(format: "linkedUserRecordName == %@", "")
            ])
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "hasOwnIPhone", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: true)
        ]
        return (try? context.fetch(request)) ?? []
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
