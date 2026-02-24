//
//  RootView.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI
import CoreData

extension Notification.Name {
    /// Posted after iOS delivers a CloudKit share acceptance to the app delegate and
    /// we successfully accept it into the shared Core Data store.
    static let didAcceptCloudKitShare = Notification.Name("didAcceptCloudKitShare")
}

struct RootView: View {
    @Environment(\.managedObjectContext) private var context
    @StateObject private var appState: AppState

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
        // ✅ If a share is accepted while the app is running (or after returning from Messages),
        // re-run start() so AppState can pick up the shared household from the shared store.
        .onReceive(NotificationCenter.default.publisher(for: .didAcceptCloudKitShare)) { _ in
            Task { await appState.start() }
        }
        .task {
            await NotificationScheduler.sync(context: context, household: appState.household)
        }
    }
}
