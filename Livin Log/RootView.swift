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
    @State private var pendingInvite: PendingShareInvite?
    @State private var lastProcessedShareURL: URL?
    @State private var showingCreateMemberProfileSheet = false
    @State private var showingMembershipChooser = false
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

            case .main:
                HomeDashboardView(household: $appState.household, member: $appState.member)
            }
        }
        .environmentObject(appState)
        .task {
            guard pendingInvite == nil else { return }
            await NotificationScheduler.sync(context: context, household: appState.household)
            resumePendingInviteIfPossible(reason: "RootView.task")
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveCloudKitShare)) { note in
            guard let metadata = note.object as? CKShare.Metadata else { return }
            if appState.appUser == nil {
                print("🔗 [PendingInvite] sign-in required before received CloudKit share can be accepted")
            }
            pendingInvite = PendingShareInvite(metadata: metadata)
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
            let needsClaim = appState.shouldPromptForSharedMemberProfile() || appState.needsMemberClaim
            showingCreateMemberProfileSheet = needsClaim
            showingMembershipChooser = !needsClaim && appState.candidateMemberships.count > 1
        }
        .onChange(of: appState.candidateMemberships.count) { _, count in
            guard appState.route == .main else { return }
            let needsClaim = appState.shouldPromptForSharedMemberProfile() || appState.needsMemberClaim
            showingMembershipChooser = !needsClaim && count > 1
        }
        .onChange(of: appState.needsMemberClaim) { _, needsClaim in
            guard appState.route == .main else { return }
            if needsClaim {
                showingMembershipChooser = false
            }
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
            pendingInvite = nil
            pendingInviteError = nil
            lastFailedPendingInviteURL = nil
            isResumingPendingInvite = false
        }
        .sheet(item: $pendingInvite) { pendingInvite in
            AcceptHouseholdInviteSheet(
                pendingInvite: pendingInvite,
                onAccepted: {
                    await appState.start(callSite: "RootView.acceptInvite.onAccepted")
                    let needsClaim = appState.shouldPromptForSharedMemberProfile() || appState.needsMemberClaim
                    showingCreateMemberProfileSheet = needsClaim
                    showingMembershipChooser = !needsClaim && appState.candidateMemberships.count > 1
                },
                onCancelInvite: {
                    PendingInviteStore.clear(reason: "cancelled from root accept sheet")
                    self.pendingInvite = nil
                }
            )
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
        .sheet(isPresented: $showingMembershipChooser) {
            MembershipPickerSheet(
                memberships: appState.candidateMemberships,
                onPicked: { membership in
                    appState.selectMembership(membership)
                    showingMembershipChooser = false
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingCreateMemberProfileSheet) {
            if let activeHousehold = appState.household {
                CreateMemberProfileSheet(household: activeHousehold) { createdMember in
                    appState.applyCreatedSharedMember(createdMember, for: activeHousehold)
                }
                .environmentObject(appState)
            }
        }
    }

    private func routeIncomingInviteURL(_ url: URL) {
        guard lastProcessedShareURL != url else { return }
        lastProcessedShareURL = url
        PendingInviteStore.save(url, reason: "incoming deep link")
        lastFailedPendingInviteURL = nil

        guard appState.appUser != nil else {
            print("🔗 [PendingInvite] sign-in required for incoming invite link")
            pendingInvite = nil
            return
        }

        Task { @MainActor in
            if let invite = await inviteRouter.pendingInvite(from: url) {
                print("🔗 [PendingInvite] presenting invite for signed-in user")
                lastFailedPendingInviteURL = nil
                pendingInvite = invite
            } else {
                lastFailedPendingInviteURL = url
                pendingInviteError = "This invite link could not be loaded. It may be invalid, expired, unavailable, or from a different iCloud account."
            }
        }
    }

    private func resumePendingInviteIfPossible(reason: String) {
        guard appState.appUser != nil else { return }
        guard pendingInvite == nil else { return }
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
                pendingInvite = invite
            } else {
                print("🔗 [PendingInvite] pending invite resume failed")
                lastFailedPendingInviteURL = url
                pendingInviteError = "This saved invite could not be loaded. It may be invalid, expired, unavailable, or from a different iCloud account."
            }
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
