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
    @State private var activeSheet: RootActiveSheet?

    init(container: NSPersistentContainer) {
        _appState = StateObject(wrappedValue: AppState(container: container))
    }

    var body: some View {
        rootContent
        .environmentObject(appState)
        .task {
            await NotificationScheduler.sync(context: context, household: appState.household)
            // Cold-launch safety net: SceneDelegate may have captured incoming share metadata
            // before this view existed to receive the live notification below (see
            // SyncController.pendingShareMetadata's doc comment).
            if let metadata = SyncController.shared.consumePendingShareMetadata() {
                await appState.handleAcceptedShare(metadata: metadata)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveCloudKitShare)) { note in
            guard let metadata = note.object as? CKShare.Metadata else { return }
            Task { await appState.handleAcceptedShare(metadata: metadata) }
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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .membershipChooser:
                MembershipPickerSheet(
                    memberships: appState.candidateMemberships,
                    currentMembership: appState.currentMembership,
                    currentHousehold: appState.household,
                    currentMember: appState.member,
                    currentAppUser: appState.appUser,
                    onCleanupCompleted: { await appState.start(callSite: "MembershipPickerSheet.cleanup") },
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
    }

    private func presentPostRouteSheet() {
        guard appState.route == .main else { return }
        let needsClaim = appState.shouldPromptForSharedMemberProfile() || appState.needsMemberClaim
        if needsClaim {
            activeSheet = .createMemberProfile
        } else if appState.candidateMemberships.count > 1 {
            activeSheet = .membershipChooser
        } else if activeSheet != nil {
            activeSheet = nil
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch appState.route {
        case .loading:
            ProgressView("Setting up Livin Log…")
                .task {
                    await appState.start(callSite: "RootView.loading.task")
                }

        case .iCloudRequired:
            ICloudRequiredView {
                Task { await appState.start(callSite: "RootView.iCloudRequired.retry") }
            }
            .environmentObject(appState)

        case .syncUnavailable:
            ICloudRequiredView(
                icon: "icloud.slash",
                title: "Can't Reach iCloud",
                message: "Livin Log couldn't sync your household. Check your connection and try again.",
                footnote: nil
            ) {
                Task { await appState.start(callSite: "RootView.syncUnavailable.retry") }
            }
            .environmentObject(appState)

        case .householdPicker:
            HouseholdPickerView()
                .environmentObject(appState)

        case .joiningHousehold:
            JoiningHouseholdView(householdName: appState.joiningHouseholdName)
                .environmentObject(appState)

        case .claimingMember:
            ClaimMemberView()
                .environmentObject(appState)

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
}

enum RootActiveSheet: Identifiable {
    case membershipChooser
    case createMemberProfile

    var id: String {
        switch self {
        case .membershipChooser: return "membershipChooser"
        case .createMemberProfile: return "createMemberProfile"
        }
    }
}

struct MembershipPickerSheet: View {
    let memberships: [HouseholdMembership]
    let currentMembership: HouseholdMembership?
    let currentHousehold: Household?
    let currentMember: HouseholdMember?
    let currentAppUser: AppUser?
    let onCleanupCompleted: (() async -> Void)?
    let onPicked: (HouseholdMembership) -> Void

    var body: some View {
        NavigationStack {
            HouseholdProfileManagementView(
                memberships: memberships,
                showsPickerTitle: true,
                currentMembership: currentMembership,
                currentHousehold: currentHousehold,
                currentMember: currentMember,
                currentAppUser: currentAppUser,
                onPicked: onPicked,
                onCleanupCompleted: onCleanupCompleted
            )
        }
    }
}
