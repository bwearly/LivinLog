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
    @State private var pendingInvite: PendingShareInvite?

    init(container: NSPersistentCloudKitContainer) {
        _appState = StateObject(wrappedValue: AppState(container: container))
    }

    var body: some View {
        Group {
            switch appState.route {
            case .loading:
                ProgressView("Setting up Livin Log…")
                    .task { await appState.start() }

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
            await NotificationScheduler.sync(context: context, household: appState.household)
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveCloudKitShare)) { note in
            guard let metadata = note.object as? CKShare.Metadata else { return }
            pendingInvite = PendingShareInvite(metadata: metadata)
        }
        .sheet(item: $pendingInvite) { pendingInvite in
            AcceptHouseholdInviteSheet(pendingInvite: pendingInvite) {
                await appState.start()
            }
        }
    }
}
