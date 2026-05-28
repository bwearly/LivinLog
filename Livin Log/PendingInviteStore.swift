import Foundation

extension Notification.Name {
    static let didCapturePendingInvite = Notification.Name("didCapturePendingInvite")
    static let didClearPendingInvite = Notification.Name("didClearPendingInvite")
}

enum PendingInviteStore {
    private static let pendingInviteURLKey = "ll_pending_invite_url"

    static func save(_ url: URL, reason: String) {
        UserDefaults.standard.set(url.absoluteString, forKey: pendingInviteURLKey)
        debug("captured pending invite url=\(url.absoluteString) reason=\(reason)")
        NotificationCenter.default.post(name: .didCapturePendingInvite, object: url)
    }

    static func load() -> URL? {
        guard let raw = UserDefaults.standard.string(forKey: pendingInviteURLKey),
              let url = URL(string: raw) else { return nil }
        return url
    }

    static func clear(reason: String) {
        UserDefaults.standard.removeObject(forKey: pendingInviteURLKey)
        debug("cleared pending invite reason=\(reason)")
        NotificationCenter.default.post(name: .didClearPendingInvite, object: nil)
    }

    private static func debug(_ message: String) {
        #if DEBUG
        print("🔗 [PendingInvite] \(message)")
        #endif
    }
}
