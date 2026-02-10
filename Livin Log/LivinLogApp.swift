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

        let container = PersistenceController.shared.container

        // Some SDKs require specifying the store using `into:`
        guard let store = container.persistentStoreCoordinator.persistentStores.first else {
            print("❌ No persistent store available to accept CloudKit share.")
            return
        }

        container.acceptShareInvitations(from: [cloudKitShareMetadata], into: store) { _, error in
            if let error {
                print("❌ Failed to accept share invite:", error)
            } else {
                print("✅ Accepted share invite.")
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
