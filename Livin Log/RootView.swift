//
//  RootView.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI
import CoreData
import CloudKit

struct RootView: View {
    @Environment(\.managedObjectContext) private var context
    @StateObject private var appState: AppState
    private let inviteRouter = InviteRouter()
    @State private var activeSheet: RootActiveSheet?
    @State private var lastProcessedShareURL: URL?
    @State private var pendingInviteError: String?
    @State private var isResumingPendingInvite = false
    @State private var lastFailedPendingInviteURL: URL?

    init(container: NSPersistentCloudKitContainer) {
        _appState = StateObject(wrappedValue: AppState(container: container))
    }

    var body: some View {
        Group {
            switch appState.route {
            case .loading:
                ProgressView("Setting up Livin Log…")
                    .task {
                        guard !isPresentingPendingInvite else { return }
                        await appState.start(callSite: "RootView.loading.task")
                    }

            case .iCloudRequired:
                ICloudRequiredView {
                    Task { await appState.start(callSite: "RootView.iCloudRequired.retry") }
                }

            case .onboarding:
                OnboardingView(onFinished: {
                    Task { await appState.start(callSite: "RootView.onboarding.finished") }
                })

            case .main:
                HomeDashboardView(household: $appState.household, member: $appState.member)
            }
        }
        .environmentObject(appState)
        .task {
            guard !isPresentingPendingInvite else { return }
            await NotificationScheduler.sync(context: context, household: appState.household)
            resumePendingInviteIfPossible(reason: "RootView.task")
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveCloudKitShare)) { note in
            guard let metadata = note.object as? CKShare.Metadata else { return }
            if appState.appUser == nil {
                print("🔗 [PendingInvite] sign-in required before received CloudKit share can be accepted")
            }
            activeSheet = .pendingInvite(PendingShareInvite(metadata: metadata))
        }
        .onOpenURL { url in
            routeIncomingInviteURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL else { return }
            routeIncomingInviteURL(url)
        }

        .onChange(of: appState.route) { _, newRoute in
            guard newRoute == .main else { return }
            presentPostRouteSheet()
        }
        .onChange(of: appState.candidateMemberships.count) { _, _ in
            guard appState.route == .main else { return }
            presentPostRouteSheet()
        }
        .onChange(of: appState.needsMemberClaim) { _, needsClaim in
            guard appState.route == .main else { return }
            if needsClaim { activeSheet = .createMemberProfile }
        }
        .onChange(of: appState.appUser?.objectID) { _, _ in
            if appState.appUser != nil {
                print("🔗 [PendingInvite] AppUser resolved; checking for pending invite")
                resumePendingInviteIfPossible(reason: "appUser resolved")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didCapturePendingInvite)) { note in
            if let capturedURL = note.object as? URL, capturedURL != lastFailedPendingInviteURL {
                lastFailedPendingInviteURL = nil
            }
            if appState.appUser == nil {
                print("🔗 [PendingInvite] pending invite captured; sign-in required")
            } else {
                resumePendingInviteIfPossible(reason: "pending invite captured")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didClearPendingInvite)) { _ in
            activeSheet = nil
            pendingInviteError = nil
            lastFailedPendingInviteURL = nil
            isResumingPendingInvite = false
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .pendingInvite(let pendingInvite):
                AcceptHouseholdInviteSheet(
                    pendingInvite: pendingInvite,
                    onAccepted: {
                        await appState.start(callSite: "RootView.acceptInvite.onAccepted")
                        presentPostRouteSheet()
                    },
                    onCancelInvite: {
                        PendingInviteStore.clear(reason: "cancelled from root accept sheet")
                        activeSheet = nil
                    }
                )
            case .membershipChooser:
                MembershipPickerSheet(
                    memberships: appState.candidateMemberships,
                    onPicked: { membership in
                        appState.selectMembership(membership)
                        activeSheet = nil
                    }
                )
                .presentationDetents([.medium, .large])
            case .createMemberProfile:
                if let activeHousehold = appState.household {
                    CreateMemberProfileSheet(household: activeHousehold) { createdMember in
                        appState.applyCreatedSharedMember(createdMember, for: activeHousehold)
                        activeSheet = nil
                    }
                    .environmentObject(appState)
                }
            }
        }
        .alert("Invite Unavailable", isPresented: Binding(get: { pendingInviteError != nil }, set: { if !$0 { pendingInviteError = nil } })) {
            Button("Keep for Later", role: .cancel) {
                pendingInviteError = nil
            }
            Button("Clear Invite", role: .destructive) {
                PendingInviteStore.clear(reason: "cleared unavailable invite from alert")
                pendingInviteError = nil
            }
        } message: {
            Text(pendingInviteError ?? "The invite could not be loaded.")
        }
    }

    private var isPresentingPendingInvite: Bool {
        if case .pendingInvite = activeSheet { return true }
        return false
    }

    private func presentPostRouteSheet() {
        guard appState.route == .main else { return }
        let needsClaim = appState.shouldPromptForSharedMemberProfile() || appState.needsMemberClaim
        if needsClaim {
            activeSheet = .createMemberProfile
        } else if appState.candidateMemberships.count > 1 {
            activeSheet = .membershipChooser
        } else if activeSheet != nil, !isPresentingPendingInvite {
            activeSheet = nil
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch appState.route {
        case .loading:
            ProgressView("Setting up Livin Log…")
                .task {
                    guard pendingInvite == nil else { return }
                    await appState.start(callSite: "RootView.loading.task")
                }

        case .iCloudRequired:
            ICloudRequiredView {
                Task { await appState.start(callSite: "RootView.iCloudRequired.retry") }
            }

        case .onboarding:
            OnboardingView(onFinished: {
                Task { await appState.start(callSite: "RootView.onboarding.finished") }
            })
            .environmentObject(appState)

        case .main:
            HomeDashboardView(household: $appState.household, member: $appState.member)
                .environmentObject(appState)
        }
    }

    private func routeIncomingInviteURL(_ url: URL) {
        guard lastProcessedShareURL != url else { return }
        lastProcessedShareURL = url
        PendingInviteStore.save(url, reason: "incoming deep link")
        lastFailedPendingInviteURL = nil

        guard appState.appUser != nil else {
            print("🔗 [PendingInvite] sign-in required for incoming invite link")
            activeSheet = nil
            return
        }

        Task { @MainActor in
            if let invite = await inviteRouter.pendingInvite(from: url) {
                print("🔗 [PendingInvite] presenting invite for signed-in user")
                lastFailedPendingInviteURL = nil
                activeSheet = .pendingInvite(invite)
            } else {
                lastFailedPendingInviteURL = url
                pendingInviteError = "This invite link could not be loaded. It may be invalid, expired, unavailable, or from a different iCloud account."
            }
        }
    }

    private func resumePendingInviteIfPossible(reason: String) {
        guard appState.appUser != nil else { return }
        guard !isPresentingPendingInvite else { return }
        guard !isResumingPendingInvite else { return }
        guard let url = PendingInviteStore.load() else { return }
        guard lastFailedPendingInviteURL != url else { return }

        isResumingPendingInvite = true
        print("🔗 [PendingInvite] resuming pending invite reason=\(reason) url=\(url.absoluteString)")
        Task { @MainActor in
            defer { isResumingPendingInvite = false }
            if let invite = await inviteRouter.pendingInvite(from: url) {
                print("🔗 [PendingInvite] pending invite resumed")
                lastFailedPendingInviteURL = nil
                activeSheet = .pendingInvite(invite)
            } else {
                print("🔗 [PendingInvite] pending invite resume failed")
                lastFailedPendingInviteURL = url
                pendingInviteError = "This saved invite could not be loaded. It may be invalid, expired, unavailable, or from a different iCloud account."
            }
        }
    }
}

enum RootActiveSheet: Identifiable {
    case pendingInvite(PendingShareInvite)
    case membershipChooser
    case createMemberProfile

    var id: String {
        switch self {
        case .pendingInvite(let invite): return "pendingInvite-\(invite.id)"
        case .membershipChooser: return "membershipChooser"
        case .createMemberProfile: return "createMemberProfile"
        }
    }
}

struct MembershipPickerSheet: View {
    let memberships: [HouseholdMembership]
    let onPicked: (HouseholdMembership) -> Void

    var body: some View {
        NavigationStack {
            HouseholdProfileManagementView(
                memberships: memberships,
                showsPickerTitle: true,
                onPicked: onPicked
            )
        }
    }
}
