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
import AuthenticationServices

extension Notification.Name {
    static let didAcceptCloudKitShare = Notification.Name("didAcceptCloudKitShare")
    static let didReceiveCloudKitShare = Notification.Name("didReceiveCloudKitShare")
    static let didRequestAppRestart = Notification.Name("didRequestAppRestart")
    static let didRequestCloudKitResync = Notification.Name("didRequestCloudKitResync")
}

@MainActor
final class AppState: ObservableObject {

    enum Route: Equatable {
        case loading
        case iCloudRequired
        case onboarding
        case main
    }

    @Published var route: Route = .loading
    @Published var household: Household?
    @Published var member: HouseholdMember?
    @Published var appUser: AppUser?
    @Published var currentMembership: HouseholdMembership?
    @Published var candidateMemberships: [HouseholdMembership] = []
    @Published var needsMemberClaim = false

    private let container: NSPersistentCloudKitContainer
    private let cloudKitContainerId = "iCloud.com.blakeearly.livinlog"
    private var cancellables = Set<AnyCancellable>()
    private var isStarting = false
    private var needsRestartAfterCurrentStart = false
    private var debouncedStartTask: Task<Void, Never>?

    init(container: NSPersistentCloudKitContainer) {
        self.container = container
        observeShareAcceptanceAndStoreChanges()
    }

    func start(callSite: String = #function) async {
        debugLog("start() invoked [\(callSite)] route=\(routeLabel(route))")

        if isStarting {
            needsRestartAfterCurrentStart = true
            debugLog("start() already in progress; coalescing into one follow-up run")
            return
        }

        isStarting = true
        defer { isStarting = false }

        if route != .main {
            setRoute(.loading, reason: "start() begin [\(callSite)]")
        }

        let status = await fetchICloudStatus()
        guard status == .available else {
            setRoute(.iCloudRequired, reason: "iCloud unavailable")
            clearResolvedIdentity(reason: "iCloud unavailable")
            await runQueuedStartIfNeeded()
            return
        }

        guard let resolvedAppUser = await resolveAuthenticatedUser() else {
            clearResolvedIdentity(reason: "no authenticated user")
            setRoute(.onboarding, reason: "auth required")
            await runQueuedStartIfNeeded()
            return
        }

        self.appUser = resolvedAppUser

        if !hasAnyHousehold() {
            setSelection(household: nil, member: nil, membership: nil, reason: "no household available")
            setRoute(.onboarding, reason: "no household available")
            await runQueuedStartIfNeeded()
            return
        }

        let memberships = IdentityStore.memberships(for: resolvedAppUser, context: container.viewContext)
        candidateMemberships = memberships

        if memberships.count == 1, let membership = memberships.first {
            applyMembership(membership, reason: "single membership")
            needsMemberClaim = false
            setRoute(.main, reason: "ready with one membership")
            await runQueuedStartIfNeeded()
            return
        }

        if memberships.count > 1 {
            if let preferred = resolvePreferredMembership(from: memberships) {
                applyMembership(preferred, reason: "resolved preferred membership")
            }
            needsMemberClaim = false
            setRoute(.main, reason: "multiple memberships require explicit selection")
            await runQueuedStartIfNeeded()
            return
        }

        guard let h = fetchPreferredHousehold() else {
            setSelection(household: nil, member: nil, membership: nil, reason: "no preferred household")
            setRoute(.onboarding, reason: "no preferred household")
            await runQueuedStartIfNeeded()
            return
        }

        if let migrated = tryAutoMigrateMembership(for: resolvedAppUser, household: h) {
            applyMembership(migrated, reason: "auto-migrated from existing local selection")
            needsMemberClaim = false
            setRoute(.main, reason: "ready after migration")
            await runQueuedStartIfNeeded()
            return
        }

        setSelection(household: h, member: nil, membership: nil, reason: "household found but no membership")
        needsMemberClaim = true
        setRoute(.main, reason: "requires claim flow")
        await runQueuedStartIfNeeded()
    }

    func handleAppleSignIn(subject: String, displayName: String?) throws {
        let user = try IdentityStore.fetchOrCreateAppUser(
            provider: IdentityStore.providerApple,
            subject: subject,
            displayName: displayName,
            context: container.viewContext
        )
        appUser = user
        AuthSessionStore.saveAppleUserSubject(subject)
    }

    func createInitialHousehold(name: String, memberName: String) throws {
        guard let appUser else {
            throw NSError(domain: "AppState", code: 100, userInfo: [NSLocalizedDescriptionKey: "Sign in is required before creating a household."])
        }

        let context = container.viewContext
        let household = Household(context: context)
        household.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Our Household" : name.trimmingCharacters(in: .whitespacesAndNewlines)

        let createdMember = HouseholdMember(context: context)
        createdMember.displayName = memberName.trimmingCharacters(in: .whitespacesAndNewlines)
        createdMember.household = household

        try context.save()
        let membership = try IdentityStore.ensureMembership(appUser: appUser, household: household, member: createdMember, role: "leader", context: context)

        setSelection(household: household, member: createdMember, membership: membership, reason: "initial household created")
        SelectionStore.save(household: household, member: createdMember)
    }

    func claim(member: HouseholdMember, role: String = "member") throws {
        guard let appUser else {
            throw NSError(domain: "AppState", code: 101, userInfo: [NSLocalizedDescriptionKey: "Sign in is required before claiming a profile."])
        }
        guard let household = member.household else {
            throw NSError(domain: "AppState", code: 102, userInfo: [NSLocalizedDescriptionKey: "Member household could not be resolved."])
        }

        let membership = try IdentityStore.ensureMembership(appUser: appUser, household: household, member: member, role: role, context: container.viewContext)
        applyMembership(membership, reason: "claimed member profile")
        needsMemberClaim = false
    }

    func createAndClaimMember(named name: String, in household: Household, role: String = "member") throws -> HouseholdMember {
        guard let appUser else {
            throw NSError(domain: "AppState", code: 103, userInfo: [NSLocalizedDescriptionKey: "Sign in is required before creating a profile."])
        }

        let context = container.viewContext
        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
            throw NSError(domain: "AppState", code: 104, userInfo: [NSLocalizedDescriptionKey: "Could not resolve household in active context."])
        }

        let member = HouseholdMember(context: context)
        member.id = UUID()
        member.createdAt = Date()
        member.displayName = name
        member.household = scopedHousehold

        try context.save()
        let membership = try IdentityStore.ensureMembership(appUser: appUser, household: scopedHousehold, member: member, role: role, context: context)
        applyMembership(membership, reason: "created and claimed member")
        needsMemberClaim = false
        return member
    }

    func selectMembership(_ membership: HouseholdMembership) {
        applyMembership(membership, reason: "selected membership")
        needsMemberClaim = false
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

    func isCurrentMemberAuthorized() -> Bool {
        IdentityStore.canAct(as: member, appUser: appUser, context: container.viewContext)
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
                if self.route == .onboarding || (self.route == .main && self.isCurrentHouseholdInPrivateStore()) {
                    self.scheduleStartDebounced(label: "NSPersistentStoreRemoteChange(primary)")
                    return
                }

                if self.route == .main,
                   let currentHousehold = self.household,
                   let store = currentHousehold.objectID.persistentStore,
                   store == PersistenceController.shared.privateStore {
                    self.scheduleStartDebounced(label: "NSPersistentStoreRemoteChange(private-main)")
                }
            }
        }
        .store(in: &cancellables)
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
        guard let membershipHousehold = membership.household,
              let membershipMember = membership.memberProfile else {
            return
        }

        setSelection(household: membershipHousehold, member: membershipMember, membership: membership, reason: reason)
        SelectionStore.save(household: membershipHousehold, member: membershipMember)
        SelectionStore.saveDeviceMember(membershipMember, for: membershipHousehold)
    }

    private func clearResolvedIdentity(reason: String) {
        setSelection(household: nil, member: nil, membership: nil, reason: reason)
        SelectionStore.save(household: nil, member: nil)
        appUser = nil
        candidateMemberships = []
        needsMemberClaim = false
    }

    private func resolvePreferredMembership(from memberships: [HouseholdMembership]) -> HouseholdMembership? {
        let context = container.viewContext
        let (selectedHousehold, selectedMember) = SelectionStore.load(context: context)

        if let selectedHousehold, let selectedMember,
           let match = memberships.first(where: {
               $0.household?.objectID == selectedHousehold.objectID &&
               $0.memberProfile?.objectID == selectedMember.objectID
           }) {
            return match
        }

        return memberships.first
    }

    private func tryAutoMigrateMembership(for appUser: AppUser, household: Household) -> HouseholdMembership? {
        let context = container.viewContext
        let (_, selectedMember) = SelectionStore.load(context: context)

        if let selectedMember,
           selectedMember.household?.objectID == household.objectID,
           let role = roleForAutoMigration(in: household) {
            return try? IdentityStore.ensureMembership(
                appUser: appUser,
                household: household,
                member: selectedMember,
                role: role,
                context: context
            )
        }

        if isSharedHousehold(household) { return nil }

        let req = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        req.predicate = NSPredicate(format: "household == %@", household)
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let members = (try? context.fetch(req)) ?? []

        guard members.count == 1, let onlyMember = members.first else { return nil }
        let role = roleForAutoMigration(in: household) ?? "leader"
        return try? IdentityStore.ensureMembership(
            appUser: appUser,
            household: household,
            member: onlyMember,
            role: role,
            context: context
        )
    }

    private func roleForAutoMigration(in household: Household) -> String? {
        let req = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "household == %@ AND status == %@", household, "active")
        let hasMembership = ((try? container.viewContext.fetch(req))?.isEmpty == false)
        return hasMembership ? "member" : "leader"
    }

    private func routeLabel(_ route: Route) -> String {
        switch route {
        case .loading: return "loading"
        case .iCloudRequired: return "iCloudRequired"
        case .onboarding: return "onboarding"
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
#if DEBUG
        let ts = ISO8601DateFormatter().string(from: Date())
        print("🧭 [AppState \(ts)] \(message)")
#endif
    }

    private func isCurrentHouseholdInPrivateStore() -> Bool {
        guard let household else { return false }
        guard let store = household.objectID.persistentStore else { return false }
        return store == PersistenceController.shared.privateStore
    }

    private func hasAnyHousehold() -> Bool {
        let ctx = container.viewContext
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "Household")
        req.fetchLimit = 1
        req.includesPendingChanges = true
        req.affectedStores = container.persistentStoreCoordinator.persistentStores

        do {
            return try ctx.count(for: req) > 0
        } catch {
            print("❌ hasAnyHousehold failed: \(error)")
            return false
        }
    }

    private func fetchPreferredHousehold() -> Household? {
        if let sharedHousehold = fetchMostRecentHousehold(in: PersistenceController.shared.sharedStore) {
            return sharedHousehold
        }
        return fetchMostRecentHousehold(in: PersistenceController.shared.privateStore)
    }

    private func fetchMostRecentHousehold(in store: NSPersistentStore) -> Household? {
        let ctx = container.viewContext

        let req = Household.fetchRequest()
        req.fetchLimit = 1
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        req.affectedStores = [store]

        do {
            return (try ctx.fetch(req).first as? Household)
        } catch {
            print("❌ fetchMostRecentHousehold failed: \(error)")
            return nil
        }
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

    private func resolveAuthenticatedUser() async -> AppUser? {
        guard let subject = AuthSessionStore.loadAppleUserSubject() else { return nil }

        let credentialState = await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: subject) { state, _ in
                continuation.resume(returning: state)
            }
        }

        guard credentialState == .authorized else {
            AuthSessionStore.clearAppleUserSubject()
            return nil
        }

        do {
            return try IdentityStore.fetchOrCreateAppUser(provider: IdentityStore.providerApple, subject: subject, displayName: nil, context: container.viewContext)
        } catch {
            print("❌ Failed to resolve authenticated user: \(error)")
            return nil
        }
    }
}
