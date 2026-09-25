//
//  NotificationPresentationDelegate.swift
//  Livin Log
//
//  Without a UNUserNotificationCenterDelegate, a notification that fires while the app is in
//  the foreground is never shown (UNUserNotificationCenter.h: "If the method is not implemented
//  ... the notification will not be presented"). Installed in AppDelegate's
//  didFinishLaunchingWithOptions, as the header requires; `shared` keeps it alive since the
//  center's `delegate` is weak.

import UserNotifications

final class NotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresentationDelegate()

    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
