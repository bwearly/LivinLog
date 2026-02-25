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
        let persistence = PersistenceController.shared

        persistence.container.acceptShareInvitations(
            from: [cloudKitShareMetadata],
            into: persistence.sharedStore
        ) { _, error in
            if let error {
                print("❌ Failed to accept CloudKit share invitation: \(error.localizedDescription)")
                return
            }

            print("✅ Successfully accepted CloudKit share invitation.")
            NotificationCenter.default.post(name: .didAcceptCloudKitShare, object: nil)
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
