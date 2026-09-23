//
//  SyncSpikeApp.swift
//  SyncSpike
//

import SwiftUI

@main
struct SyncSpikeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var syncController = SyncController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncController)
        }
    }
}
