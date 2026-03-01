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
            RootView(container: persistenceController.container)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
