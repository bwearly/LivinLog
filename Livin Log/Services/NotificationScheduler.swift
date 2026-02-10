import Foundation
import CoreData
import UserNotifications

enum NotificationScheduler {
    static let globalEnabledKey = "ll_notify_enabled"
    static let identifierPrefix = "LLCAL-"
    static let supportedTags = ["Birthday", "Anniversary", "Family", "Milestone", "Travel", "Medical", "School", "Work", "Other"]

    #if DEBUG
    private static let debugLoggingEnabled = true
    #else
    private static let debugLoggingEnabled = false
    #endif

    static func tagKey(for tag: String) -> String {
        let normalized = tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        let slug = normalized.isEmpty ? "other" : normalized
        return "ll_notify_tag_\(slug)"
    }

    static func isTagEnabled(_ tag: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: tagKey(for: tag)) as? Bool ?? true
    }

    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        log("authorization status before request: \(status.rawValue)")

        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                let updated = await center.notificationSettings().authorizationStatus
                log("authorization status after request: \(updated.rawValue), granted: \(granted)")
                return granted
            } catch {
                log("authorization request failed: \(error.localizedDescription)")
                return false
            }
        @unknown default:
            return false
        }
    }

    static func removeAllEventRequests() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let matchingIDs = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }

        guard !matchingIDs.isEmpty else {
            log("removeAllEventRequests: nothing to remove")
            return
        }

        center.removePendingNotificationRequests(withIdentifiers: matchingIDs)
        center.removeDeliveredNotifications(withIdentifiers: matchingIDs)
        log("removeAllEventRequests: removed \(matchingIDs.count) pending/delivered requests")
    }

    @MainActor
    static func sync(context: NSManagedObjectContext, household: Household? = nil, defaults: UserDefaults = .standard) async {
        let notificationsEnabled = defaults.object(forKey: globalEnabledKey) as? Bool ?? false
        let center = UNUserNotificationCenter.current()
        let authStatus = await center.notificationSettings().authorizationStatus

        log("sync start - globalEnabled: \(notificationsEnabled), authStatus: \(authStatus.rawValue)")

        if !notificationsEnabled || authStatus == .denied {
            await removeAllEventRequests()
            log("sync done - notifications globally unavailable")
            return
        }

        let fetchRequest: NSFetchRequest<LLCalendarEvent> = LLCalendarEvent.fetchRequest()
        fetchRequest.sortDescriptors = [
            NSSortDescriptor(key: "month", ascending: true),
            NSSortDescriptor(key: "day", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ]

        if let household {
            fetchRequest.predicate = NSPredicate(format: "household == %@", household)
        }

        let events: [LLCalendarEvent]
        do {
            events = try context.fetch(fetchRequest)
        } catch {
            log("sync failed: fetch error \(error.localizedDescription)")
            return
        }

        await removeAllEventRequests()

        var eligibleCount = 0
        var filteredByEventToggle = 0
        var filteredByTagToggle = 0
        var filteredInvalidDate = 0
        var scheduledCount = 0

        for event in events {
            guard event.notificationsEnabledForEvent else {
                filteredByEventToggle += 1
                continue
            }

            let eventTag = event.tagText
            guard isTagEnabled(eventTag, defaults: defaults) else {
                filteredByTagToggle += 1
                continue
            }

            guard (1...12).contains(Int(event.month)), (1...31).contains(Int(event.day)) else {
                filteredInvalidDate += 1
                continue
            }

            let eventID = event.idValue ?? UUID()
            if event.idValue == nil {
                event.idValue = eventID
            }

            let content = UNMutableNotificationContent()
            content.title = event.nameText
            content.body = "\(eventTag) is today"
            content.sound = .default

            let dateComponents = DateComponents(month: Int(event.month), day: Int(event.day), hour: 9, minute: 0)
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

            let identifier = "\(identifierPrefix)\(eventID.uuidString)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

            do {
                try await center.add(request)
                scheduledCount += 1
            } catch {
                log("failed to schedule \(identifier): \(error.localizedDescription)")
            }

            eligibleCount += 1
        }

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                log("sync warning: failed to persist generated event IDs: \(error.localizedDescription)")
                context.rollback()
            }
        }

        log("sync done - fetched: \(events.count), eligible: \(eligibleCount), scheduled: \(scheduledCount), filtered(eventToggle): \(filteredByEventToggle), filtered(tagToggle): \(filteredByTagToggle), filtered(date): \(filteredInvalidDate)")
    }

    private static func log(_ message: String) {
        guard debugLoggingEnabled else { return }
        print("🔔 NotificationScheduler: \(message)")
    }
}

private extension UNUserNotificationCenter {
    func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }
}
