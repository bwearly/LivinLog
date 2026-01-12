//
//  RootView.swift
//  Keeply
//
//  Created by Blake Early on 1/5/26.
//


import SwiftUI
import CoreData

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
                ProgressView("Setting up Keeply…")
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
    }
}
