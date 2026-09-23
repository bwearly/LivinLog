//
//  LivinLogApp.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI
import UIKit
import CloudKit
import CoreData

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        HeartbeatLogger.start()
        // Phase 1 (CKSyncEngine migration): force SyncController's lazy `static let shared` to
        // initialize now, not on first incidental access, so its remote-change observer is
        // wired up before any Movie/Household write can happen.
        _ = SyncController.shared
        return true
    }

    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        NotificationCenter.default.post(
            name: .didReceiveCloudKitShare,
            object: cloudKitShareMetadata
        )
    }
}

@main
struct LivinLogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            if let loadError = persistenceController.loadError {
                StoreRecoveryView(error: loadError)
            } else {
                RootView(container: persistenceController.container)
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
            }
        }
    }
}
