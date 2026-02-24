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
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {

        let pc = PersistenceController.shared
        let container = pc.container

        // IMPORTANT: accept shares into the SHARED store.
        let sharedStore = pc.sharedStore

        container.acceptShareInvitations(from: [cloudKitShareMetadata], into: sharedStore) { _, error in
            if let error {
                print("❌ Failed to accept share invite:", error)
                CloudSharing.saveLastShareError("Accept invite failed: \(error.localizedDescription)")
                CloudSharing.saveLastShareStatus("Share acceptance failed")
            } else {
                print("✅ Accepted share invite.")
                CloudSharing.saveLastShareError(nil)
                CloudSharing.saveLastShareStatus("Accepted CloudKit share")

                // ✅ Notify the app UI/state to refresh and pick up the shared household
                // from the shared store.
                NotificationCenter.default.post(name: .didAcceptCloudKitShare, object: nil)
            }
        }
    }
}

@main
struct LivinLogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            RootView(container: persistenceController.container)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
