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
        NotificationPresentationDelegate.install()
        return true
    }

    // Phase 3b (sharing): replaced by SceneDelegate.swift, which covers both warm
    // (`windowScene(_:userDidAcceptCloudKitShareWith:)`) and cold
    // (`scene(_:willConnectTo:options:)`'s `connectionOptions.cloudKitShareMetadata`) accept --
    // this simpler app-delegate-level hook only ever covered the warm case. Registering
    // `SceneDelegate` below is what makes UIKit call the scene-level hook instead of this one.
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
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
