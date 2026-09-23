//
//  AppDelegate.swift
//  SyncSpike
//
//  Apple's own CKSyncEngine sample (apple/sample-cloudkit-sync-engine) has NO
//  AppDelegate and never forwards didReceiveRemoteNotification to the sync
//  engine -- CKSyncEngine finds/creates its own CKDatabaseSubscription and
//  handles the resulting push internally. This file exists only to (a) call
//  registerForRemoteNotifications(), which the Push Notifications capability
//  expects the app to do, and (b) hand out the SceneDelegate class so
//  windowScene(_:userDidAcceptCloudKitShareWith:) gets called, and (c) log
//  push arrival for latency diagnostics in tests B/C.

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        SpikeLogger.log(SpikeLogger.engine, "AppDelegate didFinishLaunching, registered for remote notifications")
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        SpikeLogger.log(SpikeLogger.engine, "didRegisterForRemoteNotificationsWithDeviceToken")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SpikeLogger.error(SpikeLogger.engine, "didFailToRegisterForRemoteNotifications: \(String(describing: error))")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        SpikeLogger.log(SpikeLogger.engine, "didReceiveRemoteNotification userInfo=\(userInfo)")
        return .newData
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
