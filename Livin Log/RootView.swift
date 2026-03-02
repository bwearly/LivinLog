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
                        await appState.start()
                    }
                
            case .iCloudRequired:
                ICloudRequiredView {
                    Task { await appState.start() }
                }
                
            case .onboarding:
                OnboardingView(
                    onFinished: {
                        Task { await appState.start() }
                    }
                )
                
            case .main:
                HomeDashboardView(household: appState.household, member: appState.member)
            }
        }
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
            if appState.shouldPromptForSharedMemberProfile() {
                showingCreateMemberProfileSheet = true
            }
        }
        .sheet(item: $pendingInvite) { pendingInvite in
            AcceptHouseholdInviteSheet(pendingInvite: pendingInvite) {
                await appState.start()
                if appState.shouldPromptForSharedMemberProfile() {
                    showingCreateMemberProfileSheet = true
                }
            }
        }
        .sheet(isPresented: $showingCreateMemberProfileSheet) {
            if let sharedHousehold = appState.household {
                CreateMemberProfileSheet(household: sharedHousehold) { createdMember in
                    appState.applyCreatedSharedMember(createdMember, for: sharedHousehold)
                }
            }
        }
    }
    
    private func routeIncomingInviteURL(_ url: URL) {
        print("📩 Received URL: \(url.absoluteString)")
        
        guard lastProcessedShareURL != url else { return }
        lastProcessedShareURL = url
        
        Task { @MainActor in
            if let invite = await inviteRouter.pendingInvite(from: url) {
                print("✅ Presenting invite sheet")
                pendingInvite = invite
            } else {
                print("❌ No invite created from URL")
            }
        }
    }
}
