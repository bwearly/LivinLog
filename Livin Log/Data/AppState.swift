//
//  AppState.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import Foundation
import CloudKit
import CoreData
import Combine

extension Notification.Name {
    static let didAcceptCloudKitShare = Notification.Name("didAcceptCloudKitShare")
    static let didReceiveCloudKitShare = Notification.Name("didReceiveCloudKitShare")
    static let didRequestAppRestart = Notification.Name("didRequestAppRestart")
    static let didRequestCloudKitResync = Notification.Name("didRequestCloudKitResync")
    /// Posted by InboundChangeApplier after it saves any inbound LLCalendarEvent change, so
    /// reminders are rescheduled for events added/edited/deleted on another device.
    static let didApplyInboundCalendarEvents = Notification.Name("didApplyInboundCalendarEvents")
}

@MainActor
final class AppState: ObservableObject {

    enum Route: Equatable {
        case loading
        case iCloudRequired
        /// iCloud account is available, but we couldn't resolve who "I" am or fetch this
        /// device's data (timed out, or the identity/fetch call failed). Distinct from
        /// `.iCloudRequired` -- retrying here re-attempts sync, it doesn't send the user to
        /// Settings. Never entered speculatively; see `AppState.start()`.
        case syncUnavailable
        case onboarding
        /// This iCloud user is linked to more than one HouseholdMember (e.g. leader of more than
        /// one household created on this account) -- ask which one before landing on `.main`.
        case householdPicker
        /// Accepting an incoming CKShare and waiting for the shared engine to fetch the newly-
        /// joined household -- see `handleAcceptedShare(metadata:)`.
        case joiningHousehold
        /// Joined household is here, but this iCloud user isn't linked to any member of it yet --
        /// "Which one are you?" (see `claimableHousehold`/`claimableMembers`).
        case claimingMember
        case main
    }

    @Published var route: Route = .loading
    @Published var household: Household?
    @Published var member: HouseholdMember?
    @Published var currentUserRecordName: String?
    @Published var linkedMembers: [HouseholdMember] = []

    /// Populated while `route == .joiningHousehold` -- the share's title, for "Joining <name>…".
    @Published var joiningHouseholdName: String?
    /// Populated while `route == .claimingMember`.
    @Published var claimableHousehold: Household?
    @Published var claimableMembers: [HouseholdMember] = []
    /// The member whose `inviteParticipantID` matched the accepting participant, if any --
    /// "Are you Liz?" preselect (see `handleAcceptedShare(metadata:)`).
    @Published var preselectedClaimMemberID: NSManagedObjectID?

    // Kept for source compatibility with Settings/HouseholdProfileManagementView -- Phase 3b
    // territory, not reworked this phase (see the Phase 3a plan's "not touched" list). Always
    // nil/empty now that Sign-in-with-Apple has been removed as the identity mechanism, which
    // makes every AppUser/HouseholdMembership-gated branch in those files inert rather than
    // broken.
    @Published var appUser: AppUser?
    @Published var currentMembership: HouseholdMembership?
    @Published var candidateMemberships: [HouseholdMembership] = []
    @Published var needsMemberClaim = false

    private let container: NSPersistentContainer
    private let cloudKitContainerId = "iCloud.com.blakeearly.livinlog"
    private var cancellables = Set<AnyCancellable>()
    private var isStarting = false
    private var needsRestartAfterCurrentStart = false
    /// True while `leaveHousehold()`/`deleteHousehold()` run. Leave clears this user's own
    /// member link before the CloudKit work finishes, so a remote-change-triggered `start()`
    /// mid-way would otherwise re-route (to onboarding) out from under it.
    private var isTearingDownHousehold = false
    private var debouncedStartTask: Task<Void, Never>?

    // Prevent repeated startup churn during CloudKit reset/import storms.
    private var lastRemoteChangeStartAt: Date?
    private let remoteChangeCooldown: TimeInterval = 2.0

    /// How long start() waits for the sync engine's first fetch before giving up and routing to
    /// `.syncUnavailable` -- not a retry loop; the user taps Retry, which calls start() again
    /// from scratch. Per the Phase 3a plan: a timeout must never fall through to onboarding,
    /// since that's how duplicate households get created for a returning device that just
    /// hasn't finished its first sync yet.
    private let initialFetchTimeoutSeconds: TimeInterval = 15.0

    init(container: NSPersistentContainer) {
        self.container = container
        observeShareAcceptanceAndStoreChanges()
    }

    func start(callSite: String = #function) async {
        debugLog("start() invoked [\(callSite)] route=\(routeLabel(route))")

        // `.joiningHousehold`/`.claimingMember` are owned by `handleAcceptedShare(metadata:)`
        // for as long as they're on screen, not just for that function's own duration -- a
        // concurrently- or later-triggered `start()` (e.g. a remote-change notification firing
        // while the user is still deciding on the claim screen) must not run its own routing
        // logic and pull the rug out from under an unresolved "which one are you?" decision.
        guard route != .joiningHousehold && route != .claimingMember else {
            debugLog("start() skipped [\(callSite)]; route=\(routeLabel(route)) owns routing")
            return
        }

        guard !isTearingDownHousehold else {
            debugLog("start() skipped [\(callSite)]; household teardown in progress")
            return
        }

        if isStarting {
            needsRestartAfterCurrentStart = true
            debugLog("start() already in progress; coalescing into one follow-up run")
            return
        }

        isStarting = true
        defer { isStarting = false }

        // Keep onboarding/main/the picker/joining/claiming screens visually stable during
        // background sync churn.
        if route != .main && route != .onboarding && route != .householdPicker
            && route != .joiningHousehold && route != .claimingMember {
            setRoute(.loading, reason: "start() begin [\(callSite)]")
        }

        let status = await fetchICloudStatus()
        guard status == .available else {
            setRoute(.iCloudRequired, reason: "iCloud unavailable")
            clearResolvedIdentity(reason: "iCloud unavailable")
            await runQueuedStartIfNeeded()
            return
        }

        // Fast path: if we already know who "I" am on this device (cached from a previous
        // session, off the network -- see SyncController's on-disk cache) and a local
        // HouseholdMember is already linked to that identity, route immediately. Do not wait on
        // a CloudKit fetch just to confirm what's already sitting in the local store.
        if let cachedUserRecordName = SyncController.shared.currentUserRecordName {
            currentUserRecordName = cachedUserRecordName
            if routeUsingLocallyLinkedMembers(currentUserRecordName: cachedUserRecordName, reason: "cached identity, local lookup [\(callSite)]") {
                await runQueuedStartIfNeeded()
                return
            }
        }

        guard let resolvedUserRecordName = await SyncController.shared.resolveCurrentUserRecordName() else {
            setRoute(.syncUnavailable, reason: "could not resolve iCloud user record name")
            await runQueuedStartIfNeeded()
            return
        }
        currentUserRecordName = resolvedUserRecordName

        if routeUsingLocallyLinkedMembers(currentUserRecordName: resolvedUserRecordName, reason: "resolved identity, local lookup [\(callSite)]") {
            await runQueuedStartIfNeeded()
            return
        }

        // No local HouseholdMember linked to this user yet. That's either a genuinely new user,
        // or this device's first sync just hasn't landed the household/member rows yet -- wait
        // once for the engine's first fetch (bounded), never assume onboarding without proof.
        let outcome = await SyncController.shared.waitForInitialFetch(timeoutSeconds: initialFetchTimeoutSeconds)
        switch outcome {
        case .timedOut:
            setRoute(.syncUnavailable, reason: "timed out waiting for initial CloudKit fetch")
            await runQueuedStartIfNeeded()
            return

        case .completed:
            // The fetch landed on a background context and merges into viewContext via an async
            // `perform` block (SyncController.observeViewContextMerge) -- flush that queue before
            // re-checking, so a merge queued just before `.didFetchChanges` fired isn't missed.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                container.viewContext.perform { continuation.resume() }
            }
            if routeUsingLocallyLinkedMembers(currentUserRecordName: resolvedUserRecordName, reason: "post-fetch local lookup [\(callSite)]") {
                await runQueuedStartIfNeeded()
                return
            }
        }

        candidateMemberships = []
        needsMemberClaim = false
        setSelection(household: nil, member: nil, membership: nil, reason: "no household linked to this iCloud user after initial fetch")
        setRoute(.onboarding, reason: "noLinkedHouseholdAfterInitialFetch")
        await runQueuedStartIfNeeded()
    }

    /// Looks for local HouseholdMembers linked to `currentUserRecordName` (only ones whose
    /// household relationship has actually resolved -- a member row that arrived slightly ahead
    /// of its household isn't routable yet) and, if any are found, finishes routing and returns
    /// true. Returns false, leaving routing untouched, if none are found.
    private func routeUsingLocallyLinkedMembers(currentUserRecordName: String, reason: String) -> Bool {
        let members = IdentityStore.members(linkedTo: currentUserRecordName, context: container.viewContext)
            .filter { $0.household != nil }

        switch members.count {
        case 0:
            return false
        case 1:
            applyResolvedMember(members[0], reason: reason)
            linkedMembers = []
            setRoute(.main, reason: reason)
            return true
        default:
            linkedMembers = members
            setRoute(.householdPicker, reason: reason)
            return true
        }
    }

    /// Completes `.householdPicker` when this iCloud user is linked to more than one household.
    func selectLinkedMember(_ member: HouseholdMember) {
        applyResolvedMember(member, reason: "picked from household picker")
        linkedMembers = []
        setRoute(.main, reason: "picked from household picker")
    }

    private func applyResolvedMember(_ member: HouseholdMember, reason: String) {
        setSelection(household: member.household, member: member, membership: nil, reason: reason)
        SelectionStore.save(household: member.household, member: member)
        SelectionStore.saveDeviceMember(member, for: member.household)
    }

    /// Onboarding step 2+3: creates the household and the leader's own HouseholdMember together,
    /// stamping `linkedUserRecordName` with the current iCloud user -- that link, not Sign-in-
    /// with-Apple, is what makes this device (and any other device signed into the same iCloud
    /// account) resolve straight back into this household on a future launch.
    func createInitialHousehold(householdName: String, memberName: String, avatar: String) throws {
        guard let userRecordName = currentUserRecordName else {
            throw NSError(
                domain: "AppState",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve your iCloud identity. Check your connection and try again."]
            )
        }

        let context = container.viewContext
        let trimmedHouseholdName = householdName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMemberName = memberName.trimmingCharacters(in: .whitespacesAndNewlines)

        let household = Household(context: context)
        household.id = household.id ?? UUID()
        household.createdAt = household.createdAt ?? Date()
        household.name = trimmedHouseholdName.isEmpty ? "Our Household" : trimmedHouseholdName

        let createdMember = HouseholdMember(context: context)
        createdMember.id = createdMember.id ?? UUID()
        createdMember.createdAt = createdMember.createdAt ?? Date()
        createdMember.displayName = trimmedMemberName
        createdMember.household = household
        createdMember.setValue(household.id, forKey: "householdId")
        createdMember.setValue(avatar, forKey: "avatar")
        createdMember.setValue(userRecordName, forKey: "linkedUserRecordName")
        createdMember.setValue("leader", forKey: "role")

        try context.save()

        // Create this household's CloudKit zone now that it has a permanent objectID and a
        // stamped recordName (Data/CoreDataDefaults.swift).
        SyncController.shared.createZone(for: household)

        // Deliberately does not change `route` -- OnboardingView still has the roster step
        // ("Who else lives here?") to show. It advances to `.main` itself by calling
        // `onFinished()`, which re-runs `start()` and now finds this device's newly-linked
        // leader member via the fast local-lookup path.
        setSelection(household: household, member: createdMember, membership: nil, reason: "initial household created")
        SelectionStore.save(household: household, member: createdMember)
        SelectionStore.saveDeviceMember(createdMember, for: household)
    }

    /// Onboarding step 4 ("Who else lives here?") and Settings' "Add member": adds a member with
    /// no linked iCloud user. `hasOwnIPhone` drives the Invite eligibility/status label (see the
    /// Phase 3b plan) -- it does not itself grant any CloudKit access; a no-phone member stays
    /// actionable by anyone in the household per `IdentityStore.canAct`.
    func addRosterMember(named name: String, avatar: String, hasOwnIPhone: Bool, in household: Household) throws -> HouseholdMember {
        let context = container.viewContext
        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
            throw NSError(
                domain: "AppState",
                code: 104,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve household in active context."]
            )
        }

        let member = HouseholdMember(context: context)
        if let store = scopedHousehold.objectID.persistentStore { context.assign(member, to: store) }
        member.id = UUID()
        member.createdAt = Date()
        member.displayName = name
        member.household = scopedHousehold
        member.setValue(scopedHousehold.id, forKey: "householdId")
        member.setValue(avatar, forKey: "avatar")
        member.setValue("member", forKey: "role")
        member.setValue(hasOwnIPhone, forKey: "hasOwnIPhone")

        try context.save()
        return member
    }

    /// Leader can toggle this for any member; anyone else can only toggle it for themselves.
    /// Turning it off does not itself revoke any CloudKit access already granted -- that's
    /// "Remove access," a separate explicit action (see `removeAccess(for:household:)`).
    func setHasOwnIPhone(_ value: Bool, for targetMember: HouseholdMember) throws {
        guard let currentMember = member else {
            throw NSError(domain: "AppState", code: 112, userInfo: [NSLocalizedDescriptionKey: "Could not resolve your member profile."])
        }
        let isLeader = (currentMember.value(forKey: "role") as? String) == "leader"
        let isSelf = targetMember.objectID == currentMember.objectID
        guard isLeader || isSelf else {
            throw NSError(domain: "AppState", code: 113, userInfo: [NSLocalizedDescriptionKey: "You can only change this for yourself."])
        }
        let context = container.viewContext
        guard let scoped = try context.existingObject(with: targetMember.objectID) as? HouseholdMember else {
            throw NSError(domain: "AppState", code: 114, userInfo: [NSLocalizedDescriptionKey: "That member no longer exists."])
        }
        scoped.setValue(value, forKey: "hasOwnIPhone")
        try context.save()
    }

    // MARK: - Sharing (Phase 3b)

    /// Creates the household's share if needed and adds/reuses `member`'s one-time-URL
    /// participant, returning its shareable URL. Stamps `inviteParticipantID` immediately (the
    /// participant exists on the share as soon as this succeeds, regardless of whether the
    /// caller's share sheet is ever actually completed) -- see `markInvited(_:)` for `invitedAt`.
    func inviteMember(_ targetMember: HouseholdMember, household: Household) async throws -> URL {
        let result = try await HouseholdShareManager.invite(member: targetMember, household: household, container: SyncController.shared.ckContainer)
        let context = container.viewContext
        if let scoped = try? context.existingObject(with: targetMember.objectID) as? HouseholdMember,
           (scoped.value(forKey: "inviteParticipantID") as? String) != result.participantID {
            scoped.setValue(result.participantID, forKey: "inviteParticipantID")
            try? context.save()
        }
        return result.url
    }

    /// Called when the invite share sheet completes with an activity (not on cancel) -- see the
    /// Phase 3b plan's "Record invitedAt ... when the sheet completes with an activity."
    func markInvited(_ targetMember: HouseholdMember) {
        let context = container.viewContext
        guard let scoped = try? context.existingObject(with: targetMember.objectID) as? HouseholdMember else { return }
        scoped.setValue(Date(), forKey: "invitedAt")
        try? context.save()
    }

    /// Revokes `targetMember`'s CloudKit access (see `HouseholdShareManager.removeAccess`) and
    /// clears their local link, keeping the profile and all their history per the Phase 3b plan.
    func removeAccess(for targetMember: HouseholdMember, household: Household) async throws {
        try await HouseholdShareManager.removeAccess(for: targetMember, household: household, container: SyncController.shared.ckContainer)
        let context = container.viewContext
        guard let scoped = try? context.existingObject(with: targetMember.objectID) as? HouseholdMember else { return }
        scoped.setValue(nil, forKey: "linkedUserRecordName")
        try? context.save()
    }

    // MARK: - Settings: household + profile

    /// True when this device's iCloud user owns the current household's zone, i.e. created it
    /// (the "leader"). Uses the zone's owner rather than `role`, since ownership is what decides
    /// whether Delete (owner) or Leave (participant) is even possible in CloudKit.
    var isCurrentHouseholdOwner: Bool {
        guard let household, let zoneID = SyncRecordMapping.zoneID(for: household) else { return false }
        return zoneID.ownerName == CKCurrentUserDefaultName || zoneID.ownerName == currentUserRecordName
    }

    /// Other members of the current household linked to an iCloud account -- the people a
    /// Delete also removes the household for.
    func otherLinkedMembers() -> [HouseholdMember] {
        guard let household else { return [] }
        let request = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            householdScopedPredicate(household, idKey: "householdId"),
            NSPredicate(format: "isActive == YES"),
            NSPredicate(format: "linkedUserRecordName != nil AND linkedUserRecordName != ''")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "displayName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))]
        let members = (try? container.viewContext.fetch(request)) ?? []
        return members.filter { $0.objectID != member?.objectID }
    }

    /// Leader only. Saves the new name (synced like any other Household field), then updates the
    /// share's title in the background, best-effort -- a failure there only affects the title
    /// the system's invite UI shows.
    func renameHousehold(_ newName: String) throws {
        guard isCurrentHouseholdOwner, let household else {
            throw NSError(domain: "AppState", code: 120, userInfo: [NSLocalizedDescriptionKey: "Only the household leader can rename it."])
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "AppState", code: 121, userInfo: [NSLocalizedDescriptionKey: "Household name can't be empty."])
        }
        guard trimmed != household.name else { return }

        household.name = trimmed
        try container.viewContext.save()

        Task {
            do {
                try await HouseholdShareManager.updateTitle(to: trimmed, for: household, container: SyncController.shared.ckContainer)
            } catch {
                debugLog("share title update failed (non-fatal): \(error.localizedDescription)")
            }
        }
    }

    /// Who may edit a member's profile (name, color, birthday): yourself; the leader, for
    /// anyone; and anyone, for a member not linked to an iCloud account (a no-phone member such
    /// as a child, or someone not yet joined) -- mirroring `IdentityStore.canAct`'s rule that an
    /// unlinked member is actionable by the whole household. A linked adult's profile is theirs.
    func canEditProfile(of target: HouseholdMember) -> Bool {
        guard let member else { return false }
        if target.objectID == member.objectID { return true }
        if (member.value(forKey: "role") as? String) == "leader" { return true }
        let linked = (target.value(forKey: "linkedUserRecordName") as? String).flatMap { $0.isEmpty ? nil : $0 }
        return linked == nil
    }

    /// Edits a member's profile (see `canEditProfile(of:)`). `birthday` nil clears it.
    func updateMemberProfile(_ target: HouseholdMember, name: String, avatar: String, birthday: Date?) throws {
        guard canEditProfile(of: target) else {
            throw NSError(domain: "AppState", code: 122, userInfo: [NSLocalizedDescriptionKey: "You can't edit this member's profile."])
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "AppState", code: 123, userInfo: [NSLocalizedDescriptionKey: "Name can't be empty."])
        }
        let context = container.viewContext
        guard let scoped = try context.existingObject(with: target.objectID) as? HouseholdMember else {
            throw NSError(domain: "AppState", code: 128, userInfo: [NSLocalizedDescriptionKey: "That member no longer exists."])
        }
        // Assign only what actually differs, so an unchanged Save never produces a sync.
        let newBirthday = birthday.map(Self.normalizedBirthday)
        var didChange = false
        if scoped.displayName != trimmed {
            scoped.displayName = trimmed
            didChange = true
        }
        if (scoped.value(forKey: "avatar") as? String) != avatar {
            scoped.setValue(avatar, forKey: "avatar")
            didChange = true
        }
        if (scoped.value(forKey: "birthday") as? Date) != newBirthday {
            scoped.setValue(newBirthday, forKey: "birthday")
            didChange = true
        }
        guard didChange else { return }
        try context.save()
    }

    /// Stores a birthday as noon local time on that day, so a small time-zone difference
    /// between household devices can't shift it to the previous/next calendar day.
    static func normalizedBirthday(_ date: Date) -> Date {
        let calendar = Calendar.current
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? date
    }

    // MARK: - Settings: leave / delete

    /// Participant only. 1) In one save, unlinks this user's own member (so the leader's roster
    /// stops showing them as Joined), 2) waits up to ~5s for that to send (best-effort),
    /// 3) deletes the zone-wide share from the shared DB (see HouseholdShareManager.leave),
    /// 4) removes local data and re-routes. If step 3 fails, the unlink is rolled back locally
    /// and the error is thrown -- the user is still a participant, so nothing else changes.
    func leaveHousehold() async throws {
        guard let household, let member, !isCurrentHouseholdOwner,
              let zoneID = SyncRecordMapping.zoneID(for: household) else {
            throw NSError(domain: "AppState", code: 124, userInfo: [NSLocalizedDescriptionKey: "This household can't be left from this device."])
        }
        guard !SyncStatus.shared.isOffline else {
            throw NSError(domain: "AppState", code: 125, userInfo: [NSLocalizedDescriptionKey: "You're offline. Connect to the internet to leave this household."])
        }

        isTearingDownHousehold = true
        defer { isTearingDownHousehold = false }

        let context = container.viewContext
        let previousLink = member.value(forKey: "linkedUserRecordName")
        let previousInvitedAt = member.value(forKey: "invitedAt")
        let previousParticipantID = member.value(forKey: "inviteParticipantID")
        member.setValue(nil, forKey: "linkedUserRecordName")
        member.setValue(nil, forKey: "invitedAt")
        member.setValue(nil, forKey: "inviteParticipantID")
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        let sent = await SyncController.shared.flushSharedChanges(timeoutSeconds: 5)
        debugLog("leaveHousehold: unlink send \(sent ? "completed" : "failed or timed out; leaving anyway")")

        do {
            try await HouseholdShareManager.leave(household: household, container: SyncController.shared.ckContainer)
        } catch {
            member.setValue(previousLink, forKey: "linkedUserRecordName")
            member.setValue(previousInvitedAt, forKey: "invitedAt")
            member.setValue(previousParticipantID, forKey: "inviteParticipantID")
            try? context.save()
            throw error
        }

        await SyncController.shared.deleteLocalHousehold(zoneID: zoneID)
        await finishHouseholdTeardown(reason: "left household")
    }

    /// Leader only. Deletes the household's zone for everyone (see
    /// SyncController.deleteOwnedHousehold), removes local data, and re-routes.
    func deleteHousehold() async throws {
        guard let household, isCurrentHouseholdOwner,
              let zoneID = SyncRecordMapping.zoneID(for: household) else {
            throw NSError(domain: "AppState", code: 126, userInfo: [NSLocalizedDescriptionKey: "Only the household leader can delete it."])
        }
        guard !SyncStatus.shared.isOffline else {
            throw NSError(domain: "AppState", code: 127, userInfo: [NSLocalizedDescriptionKey: "You're offline. Connect to the internet to delete this household."])
        }

        isTearingDownHousehold = true
        defer { isTearingDownHousehold = false }

        await SyncController.shared.deleteOwnedHousehold(zoneID: zoneID)
        await finishHouseholdTeardown(reason: "deleted household")
    }

    /// Clears the (now-deleted) selection and hands routing back to `start()` via `.loading`,
    /// which lands on another linked household, the picker, or onboarding.
    private func finishHouseholdTeardown(reason: String) async {
        // Flush the queued merge of the "sync"-authored delete into viewContext first, so
        // start()'s local lookup can't still see the deleted household's members.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            container.viewContext.perform { continuation.resume() }
        }
        setSelection(household: nil, member: nil, membership: nil, reason: reason)
        SelectionStore.save(household: nil, member: nil)
        isTearingDownHousehold = false
        setRoute(.loading, reason: reason)
    }

    /// Handles an incoming CKShare from either SceneDelegate hook. Routes through
    /// `.joiningHousehold` while the shared engine fetches the newly-accepted zone, then either
    /// straight to `.main` (already linked here) or `.claimingMember` ("Which one are you?").
    func handleAcceptedShare(metadata: CKShare.Metadata) async {
        joiningHouseholdName = metadata.share[CKShare.SystemFieldKey.title] as? String
        setRoute(.joiningHousehold, reason: "accepting share")

        do {
            try await SyncController.shared.acceptShare(metadata: metadata)
        } catch {
            debugLog("acceptShare failed: \(error.localizedDescription)")
            joiningHouseholdName = nil
            setRoute(.syncUnavailable, reason: "acceptShare failed")
            await runQueuedStartIfNeeded()
            return
        }

        // `acceptShare`'s `sharedEngine.fetchChanges()` kick doesn't guarantee the fetched
        // Household has been applied and merged into viewContext by the time it returns (see
        // SyncController's doc comment) -- poll under the same bound as `waitForInitialFetch`
        // rather than assume ordering that isn't contractually guaranteed.
        let zoneID = metadata.share.recordID.zoneID
        let deadline = Date().addingTimeInterval(initialFetchTimeoutSeconds)
        var joinedHousehold: Household?
        repeat {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                container.viewContext.perform { continuation.resume() }
            }
            joinedHousehold = SyncController.shared.household(matchingZoneID: zoneID)
            if joinedHousehold == nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        } while joinedHousehold == nil && Date() < deadline

        guard let joinedHousehold else {
            joiningHouseholdName = nil
            setRoute(.syncUnavailable, reason: "joined household did not sync in time")
            await runQueuedStartIfNeeded()
            return
        }

        // Already linked here (e.g. re-tapping an old invite link) -- skip the picker.
        if let currentUserRecordName,
           let existing = IdentityStore.members(linkedTo: currentUserRecordName, context: container.viewContext)
            .first(where: { $0.household?.objectID == joinedHousehold.objectID }) {
            joiningHouseholdName = nil
            applyResolvedMember(existing, reason: "already linked in joined household")
            setRoute(.main, reason: "already linked in joined household")
            await runQueuedStartIfNeeded()
            return
        }

        let acceptingParticipantID = metadata.share.currentUserParticipant?.participantID
        let unclaimed = IdentityStore.membersAwaitingLink(in: joinedHousehold, context: container.viewContext)

        joiningHouseholdName = nil
        claimableHousehold = joinedHousehold
        claimableMembers = unclaimed
        preselectedClaimMemberID = acceptingParticipantID.flatMap { participantID in
            unclaimed.first { ($0.value(forKey: "inviteParticipantID") as? String) == participantID }?.objectID
        }
        setRoute(.claimingMember, reason: "joined household, awaiting claim")
        await runQueuedStartIfNeeded()
    }

    /// "Which one are you?" -- claims an existing unlinked member as this iCloud user.
    func claimMember(_ targetMember: HouseholdMember) throws {
        guard let currentUserRecordName else {
            throw NSError(domain: "AppState", code: 115, userInfo: [NSLocalizedDescriptionKey: "Could not resolve your iCloud identity."])
        }
        let context = container.viewContext
        guard let scoped = try context.existingObject(with: targetMember.objectID) as? HouseholdMember else {
            throw NSError(domain: "AppState", code: 116, userInfo: [NSLocalizedDescriptionKey: "That profile no longer exists."])
        }
        scoped.setValue(currentUserRecordName, forKey: "linkedUserRecordName")
        scoped.setValue("member", forKey: "role")
        try context.save()
        finishClaim(scoped)
    }

    /// "I'm not listed" -- creates a fresh member (always `hasOwnIPhone = true`, per the Phase 3b
    /// plan: whoever is running through this flow is, by definition, using their own iPhone) and
    /// claims it in one step.
    func createAndClaimNewMember(named name: String, avatar: String, in household: Household) throws {
        guard let currentUserRecordName else {
            throw NSError(domain: "AppState", code: 117, userInfo: [NSLocalizedDescriptionKey: "Could not resolve your iCloud identity."])
        }
        let created = try addRosterMember(named: name, avatar: avatar, hasOwnIPhone: true, in: household)
        let context = container.viewContext
        guard let scoped = try context.existingObject(with: created.objectID) as? HouseholdMember else {
            throw NSError(domain: "AppState", code: 118, userInfo: [NSLocalizedDescriptionKey: "Could not resolve the created profile."])
        }
        scoped.setValue(currentUserRecordName, forKey: "linkedUserRecordName")
        scoped.setValue("member", forKey: "role")
        try context.save()
        finishClaim(scoped)
    }

    private func finishClaim(_ claimedMember: HouseholdMember) {
        applyResolvedMember(claimedMember, reason: "claimed member on join")
        claimableHousehold = nil
        claimableMembers = []
        preselectedClaimMemberID = nil
        setRoute(.main, reason: "claimed member on join")
    }

    // MARK: - Phase 3b-adjacent, kept for source compatibility (see file header)

    /// Unreachable in Phase 3a: `needsMemberClaim` is never set true and `shouldPromptForSharedMemberProfile()`
    /// always returns false (no shared household can exist yet), so RootView never presents the
    /// sheet that calls this. Left intact rather than deleted since RootView/CreateMemberProfileSheet
    /// (Phase 3b territory) aren't being reworked this phase.
    func claim(member: HouseholdMember, role: String = "member") throws {
        guard let appUser else {
            throw NSError(
                domain: "AppState",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "Sign in is required before claiming a profile."]
            )
        }

        guard let household = member.household else {
            throw NSError(
                domain: "AppState",
                code: 102,
                userInfo: [NSLocalizedDescriptionKey: "Member household could not be resolved."]
            )
        }

        let membership = try IdentityStore.ensureMembership(
            appUser: appUser,
            household: household,
            member: member,
            role: role,
            context: container.viewContext
        )

        applyMembership(membership, reason: "claimed member profile")
        needsMemberClaim = false
    }

    /// See `claim(member:role:)` above -- same "unreachable, kept for compatibility" note.
    func createAndClaimMember(named name: String, in household: Household, role: String = "member") throws -> HouseholdMember {
        guard let appUser else {
            throw NSError(
                domain: "AppState",
                code: 103,
                userInfo: [NSLocalizedDescriptionKey: "Sign in is required before creating a profile."]
            )
        }

        let context = container.viewContext
        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
            throw NSError(
                domain: "AppState",
                code: 104,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve household in active context."]
            )
        }

        if let existingMembership = IdentityStore.activeMembership(for: appUser, household: scopedHousehold, context: context),
           let existingMember = existingMembership.memberProfile {
            applyMembership(existingMembership, reason: "reused existing household membership")
            needsMemberClaim = false
            return existingMember
        }

        let member = HouseholdMember(context: context)
        if let store = scopedHousehold.objectID.persistentStore { context.assign(member, to: store) }
        member.id = UUID()
        member.createdAt = Date()
        member.displayName = name
        member.household = scopedHousehold
        member.setValue(scopedHousehold.id, forKey: "householdId")

        try context.save()

        let membership = try IdentityStore.ensureMembership(
            appUser: appUser,
            household: scopedHousehold,
            member: member,
            role: role,
            context: context
        )

        applyMembership(membership, reason: "created and claimed member")
        needsMemberClaim = false
        return member
    }

    func selectMembership(_ membership: HouseholdMembership) {
        applyMembership(membership, reason: "selected membership")
        needsMemberClaim = false
    }

    func applyCreatedSharedMember(_ createdMember: HouseholdMember, for household: Household) {
        self.household = household
        self.member = createdMember
        SelectionStore.save(household: household, member: createdMember)
        SelectionStore.saveDeviceMember(createdMember, for: household)
    }

    func shouldPromptForSharedMemberProfile() -> Bool {
        guard let household else { return false }
        return isSharedHousehold(household) && (member == nil || !isCurrentMemberAuthorized())
    }

    // MARK: - Authorization

    func isCurrentMemberAuthorized() -> Bool {
        IdentityStore.canAct(as: member, currentUserRecordName: currentUserRecordName)
    }

    func scheduleStartDebounced(label: String, delayNanoseconds: UInt64 = 350_000_000) {
        debugLog("scheduleStartDebounced requested [\(label)]")
        debouncedStartTask?.cancel()
        debouncedStartTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            await start(callSite: "debounced: \(label)")
        }
    }

    private func observeShareAcceptanceAndStoreChanges() {
        NotificationCenter.default.publisher(for: .didAcceptCloudKitShare)
            .sink { [weak self] _ in
                self?.scheduleStartDebounced(label: "didAcceptCloudKitShare")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .didRequestAppRestart)
            .sink { [weak self] _ in
                self?.scheduleStartDebounced(label: "didRequestAppRestart")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .didRequestCloudKitResync)
            .sink { [weak self] _ in
                self?.scheduleStartDebounced(label: "didRequestCloudKitResync", delayNanoseconds: 0)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator
        )
        .sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.shouldHandleRemoteChange() else {
                    self.debugLog("skipping remote change due to cooldown")
                    return
                }

                // Keep onboarding stable during CloudKit zone reset storms.
                // Only re-evaluate if we are already on main and our selection may have changed.
                guard self.route == .main else { return }

                if self.household == nil || self.member == nil {
                    self.scheduleStartDebounced(label: "NSPersistentStoreRemoteChange(main-unresolved)")
                    return
                }

                if self.isCurrentHouseholdInPrivateStore() {
                    self.scheduleStartDebounced(label: "NSPersistentStoreRemoteChange(private-main)")
                }
            }
        }
        .store(in: &cancellables)
    }

    private func shouldHandleRemoteChange() -> Bool {
        let now = Date()
        if let lastRemoteChangeStartAt,
           now.timeIntervalSince(lastRemoteChangeStartAt) < remoteChangeCooldown {
            return false
        }
        lastRemoteChangeStartAt = now
        return true
    }

    private func runQueuedStartIfNeeded() async {
        guard needsRestartAfterCurrentStart else { return }
        needsRestartAfterCurrentStart = false
        await start(callSite: "queued-after-inflight")
    }

    private func setRoute(_ newRoute: Route, reason: String) {
        let oldRoute = route
        route = newRoute
        if oldRoute != newRoute {
            debugLog("route changed \(routeLabel(oldRoute)) -> \(routeLabel(newRoute)) [\(reason)]")
        }
        SetupDiagnostics.logRouteDecision(
            route: routeLabel(newRoute),
            reason: reason,
            appUser: appUser,
            household: household,
            member: member,
            membership: currentMembership,
            candidateMembershipCount: candidateMemberships.count,
            context: container.viewContext
        )
    }

    private func setSelection(household: Household?, member: HouseholdMember?, membership: HouseholdMembership?, reason: String) {
        let oldHousehold = self.household
        let oldMember = self.member

        self.household = household
        self.member = member
        self.currentMembership = membership

        if oldHousehold?.objectID != household?.objectID {
            debugLog("household changed \(describe(oldHousehold)) -> \(describe(household)) [\(reason)]")
        }
        if oldMember?.objectID != member?.objectID {
            debugLog("member changed \(describe(oldMember)) -> \(describe(member)) [\(reason)]")
        }
    }

    private func applyMembership(_ membership: HouseholdMembership, reason: String) {
        IdentityStore.backfillMembershipIfPossible(membership)
        if container.viewContext.hasChanges {
            do {
                try container.viewContext.save()
            } catch {
                debugLog("failed to backfill selected membership: \(error.localizedDescription)")
            }
        }

        guard let membershipHousehold = membership.household,
              let membershipMember = membership.memberProfile else {
            return
        }

        setSelection(
            household: membershipHousehold,
            member: membershipMember,
            membership: membership,
            reason: reason
        )

        SelectionStore.save(household: membershipHousehold, member: membershipMember)
        SelectionStore.saveDeviceMember(membershipMember, for: membershipHousehold)
    }

    private func clearResolvedIdentity(reason: String) {
        setSelection(household: nil, member: nil, membership: nil, reason: reason)
        SelectionStore.save(household: nil, member: nil)
        currentUserRecordName = nil
        linkedMembers = []
        joiningHouseholdName = nil
        claimableHousehold = nil
        claimableMembers = []
        preselectedClaimMemberID = nil
        appUser = nil
        candidateMemberships = []
        needsMemberClaim = false
    }

    private func routeLabel(_ route: Route) -> String {
        switch route {
        case .loading: return "loading"
        case .iCloudRequired: return "iCloudRequired"
        case .syncUnavailable: return "syncUnavailable"
        case .onboarding: return "onboarding"
        case .householdPicker: return "householdPicker"
        case .joiningHousehold: return "joiningHousehold"
        case .claimingMember: return "claimingMember"
        case .main: return "main"
        }
    }

    private func describe(_ household: Household?) -> String {
        guard let household else { return "nil" }
        return household.name ?? household.objectID.uriRepresentation().lastPathComponent
    }

    private func describe(_ member: HouseholdMember?) -> String {
        guard let member else { return "nil" }
        return member.displayName ?? member.objectID.uriRepresentation().lastPathComponent
    }

    private func debugLog(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        print("🧭 [AppState \(ts)] \(message)")
    }

    private func isCurrentHouseholdInPrivateStore() -> Bool {
        guard let household else { return false }
        guard let store = household.objectID.persistentStore else { return false }
        return store == PersistenceController.shared.privateStore
    }

    private func isSharedHousehold(_ household: Household) -> Bool {
        household.objectID.persistentStore == PersistenceController.shared.sharedStore
    }

    private func fetchICloudStatus() async -> CKAccountStatus {
        await withCheckedContinuation { continuation in
            CKContainer(identifier: cloudKitContainerId).accountStatus { status, _ in
                continuation.resume(returning: status)
            }
        }
    }
}
