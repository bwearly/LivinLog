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

        // Root cause observed: remote-change/import notifications arrive in bursts after
        // share accept + profile creation. Re-entering `.loading` while already on `.main`
        // causes visible route churn/flicker. Keep `.main` stable during refreshes.
        if route != .main {
            setRoute(.loading, reason: "start() begin [\(callSite)]")
        } else {
            debugLog("start() keeping route=.main during refresh")
        }

        let status = await fetchICloudStatus()
        guard status == .available else {
            setRoute(.iCloudRequired, reason: "iCloud unavailable")
            setSelection(household: nil, member: nil, reason: "iCloud unavailable")
            SelectionStore.save(household: nil, member: nil)
            await runQueuedStartIfNeeded()
            return
        }

        guard hasAnyHousehold(), let h = fetchPreferredHousehold() else {
            setSelection(household: nil, member: nil, reason: "no household available")
            SelectionStore.save(household: nil, member: nil)
            setRoute(.onboarding, reason: "no household available")
            await runQueuedStartIfNeeded()
            return
        }

        let resolvedMember = resolveMember(for: h)
        setSelection(household: h, member: resolvedMember, reason: "resolved preferred household/member")
        SelectionStore.save(household: household, member: member)
        setRoute(.main, reason: "ready with valid household")
        await runQueuedStartIfNeeded()
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
        return isSharedHousehold(household) && !validateSelectionMember(member, for: household)
    }

    private func observeShareAcceptanceAndStoreChanges() {
        // When an invite is accepted, re-evaluate routing/selection.
        NotificationCenter.default.publisher(for: .didAcceptCloudKitShare)
            .sink { [weak self] _ in
                self?.debugLog("notification received: didAcceptCloudKitShare")
                self?.scheduleStartDebounced(label: "didAcceptCloudKitShare")
            }
            .store(in: &cancellables)

        // Handle local data reset requests.
        NotificationCenter.default.publisher(for: .didRequestAppRestart)
            .sink { [weak self] _ in
                self?.debugLog("notification received: didRequestAppRestart")
                self?.scheduleStartDebounced(label: "didRequestAppRestart")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .didRequestCloudKitResync)
            .sink { [weak self] _ in
                self?.debugLog("notification received: didRequestCloudKitResync")
                self?.scheduleStartDebounced(label: "didRequestCloudKitResync", delayNanoseconds: 0)
            }
            .store(in: &cancellables)

        // When CloudKit imports new data (e.g., shared household arrives), re-evaluate.
        NotificationCenter.default.publisher(
            for: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator
        )
        .sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.debugLog("notification received: NSPersistentStoreRemoteChange")
                if self.route == .onboarding || (self.route == .main && self.isCurrentHouseholdInPrivateStore()) {
                    self.scheduleStartDebounced(label: "NSPersistentStoreRemoteChange(primary)")
                    return
                }

                // If we’re already on main but still using a PRIVATE household,
                // a shared household may have just arrived—re-evaluate.
                if self.route == .main,
                   let currentHousehold = self.household,
                   let store = currentHousehold.objectID.persistentStore,
                   store == PersistenceController.shared.privateStore {
                    self.scheduleStartDebounced(label: "NSPersistentStoreRemoteChange(private-main)")
                }
            }
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container
        )
        .sink { [weak self] _ in
            self?.debugLog("notification received: NSPersistentCloudKitContainer.eventChangedNotification")
        }
        .store(in: &cancellables)
    }

    private func runQueuedStartIfNeeded() async {
        guard needsRestartAfterCurrentStart else { return }
        needsRestartAfterCurrentStart = false
        debugLog("running queued start() after previous run completed")
        await start(callSite: "queued-after-inflight")
    }

    private func setRoute(_ newRoute: Route, reason: String) {
        let oldRoute = route
        route = newRoute
        if oldRoute != newRoute {
            debugLog("route changed \(routeLabel(oldRoute)) -> \(routeLabel(newRoute)) [\(reason)]")
        }
    }

    private func setSelection(household: Household?, member: HouseholdMember?, reason: String) {
        let oldHousehold = self.household
        let oldMember = self.member
        self.household = household
        self.member = member

        if oldHousehold?.objectID != household?.objectID {
            debugLog("household changed \(describe(oldHousehold)) -> \(describe(household)) [\(reason)]")
        }
        if oldMember?.objectID != member?.objectID {
            debugLog("member changed \(describe(oldMember)) -> \(describe(member)) [\(reason)]")
        }
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

    /// Option A: Prefer shared household if any exist; otherwise fall back to private.
    private func fetchPreferredHousehold() -> Household? {
        if let sharedHousehold = fetchMostRecentHousehold(in: PersistenceController.shared.sharedStore) {
            let identifier = sharedHousehold.name ?? sharedHousehold.objectID.uriRepresentation().absoluteString
            print("✅ Switched active household to shared: \(identifier)")
            print("🧪 [Selection] activeStore=shared household=\(identifier)")
            return sharedHousehold
        }

        print("ℹ️ No shared households found; using private household")
        let privateHousehold = fetchMostRecentHousehold(in: PersistenceController.shared.privateStore)
        if let privateHousehold {
            let identifier = privateHousehold.name ?? privateHousehold.objectID.uriRepresentation().absoluteString
            print("🧪 [Selection] activeStore=private household=\(identifier)")
        }
        return privateHousehold
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

    private func resolveMember(for household: Household) -> HouseholdMember? {
        let ctx = container.viewContext

        let (_, selectedMember) = SelectionStore.load(context: ctx)
        if validateSelectionMember(selectedMember, for: household) {
            print("✅ Using existing selected member for this household")
            SelectionStore.saveDeviceMember(selectedMember, for: household)
            return selectedMember
        }

        if let deviceMember = SelectionStore.loadDeviceMember(for: household, context: ctx),
           validateSelectionMember(deviceMember, for: household) {
            print("✅ Using existing selected member for this household")
            return deviceMember
        }

        if isSharedHousehold(household) {
            print("ℹ️ Selected household is shared; no local member found; prompting for name")
            return nil
        }

        return ensureDefaultPrivateMemberExists(for: household)
    }

    private func ensureDefaultPrivateMemberExists(for household: Household) -> HouseholdMember? {
        let ctx = container.viewContext

        let req = HouseholdMember.fetchRequest()
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "household == %@", household)

        do {
            if let existing = try ctx.fetch(req).first as? HouseholdMember {
                return existing
            }

            let me = HouseholdMember(context: ctx)
            me.id = UUID()
            me.createdAt = Date()
            me.displayName = "Me"
            me.household = household

            try ctx.save()
            return me
        } catch {
            print("❌ ensureDefaultPrivateMemberExists failed: \(error)")
            ctx.rollback()
            return nil
        }
    }

    private func validateSelectionMember(_ candidate: HouseholdMember?, for household: Household) -> Bool {
        guard let candidate else { return false }
        return candidate.household?.objectID == household.objectID
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
