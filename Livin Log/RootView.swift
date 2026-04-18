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
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveCloudKitShare)) { note in
            guard let metadata = note.object as? CKShare.Metadata else { return }
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
            if appState.shouldPromptForSharedMemberProfile() || appState.needsMemberClaim {
                showingCreateMemberProfileSheet = true
            }
            showingMembershipChooser = appState.candidateMemberships.count > 1
        }
        .onChange(of: appState.candidateMemberships.count) { _, count in
            guard appState.route == .main else { return }
            showingMembershipChooser = count > 1
        }
        .sheet(item: $pendingInvite) { pendingInvite in
            AcceptHouseholdInviteSheet(pendingInvite: pendingInvite) {
                await appState.start(callSite: "RootView.acceptInvite.onAccepted")
                if appState.shouldPromptForSharedMemberProfile() || appState.needsMemberClaim {
                    showingCreateMemberProfileSheet = true
                }
            }
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

        Task { @MainActor in
            if let invite = await inviteRouter.pendingInvite(from: url) {
                pendingInvite = invite
            }
        }
    }
}

struct MembershipPickerSheet: View {
    let memberships: [HouseholdMembership]
    let onPicked: (HouseholdMembership) -> Void

    var body: some View {
        NavigationStack {
            List(memberships, id: \.objectID) { membership in
                Button {
                    onPicked(membership)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(membership.household?.name ?? "Household")
                            .font(.headline)
                        Text(membership.memberProfile?.displayName ?? "Member")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Choose Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
