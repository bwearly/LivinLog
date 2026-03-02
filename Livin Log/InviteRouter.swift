import Foundation
import CloudKit

final class InviteRouter {
    private let container: CKContainer

    init(containerIdentifier: String = "iCloud.com.blakeearly.livinlog") {
        container = CKContainer(identifier: containerIdentifier)
    }

    func pendingInvite(from url: URL) async -> PendingShareInvite? {
        // ✅ Normalize: remove fragment (#...) which often breaks metadata fetch
        let normalized = Self.stripFragment(url)

        guard isICloudShareURL(normalized) else {
            print("ℹ️ Not an iCloud share URL: \(normalized.absoluteString)")
            return nil
        }

        return await withCheckedContinuation { continuation in
            container.fetchShareMetadata(with: normalized) { metadata, error in
                if let error {
                    print("❌ Failed to fetch share metadata for \(normalized.absoluteString): \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                guard let metadata else {
                    print("❌ Failed to fetch share metadata: metadata is nil for \(normalized.absoluteString)")
                    continuation.resume(returning: nil)
                    return
                }

                print("✅ Fetched share metadata for \(normalized.absoluteString)")
                continuation.resume(returning: PendingShareInvite(metadata: metadata))
            }
        }
    }

    private static func stripFragment(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.fragment = nil
        return comps.url ?? url
    }

    private func isICloudShareURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let hostContainsICloud = host.contains("icloud.com")

        // ✅ Accept /share/<token> and /share/ forms
        let pathContainsShare = path.contains("/share/") || path.hasPrefix("/share")

        return hostContainsICloud && pathContainsShare
    }
}
