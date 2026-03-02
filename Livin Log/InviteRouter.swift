import Foundation
import CloudKit

final class InviteRouter {
    private let container: CKContainer

    init(containerIdentifier: String = "iCloud.com.blakeearly.livinlog") {
        container = CKContainer(identifier: containerIdentifier)
    }

    func pendingInvite(from url: URL) async -> PendingShareInvite? {
        guard isICloudShareURL(url) else { return nil }

        return await withCheckedContinuation { continuation in
            container.fetchShareMetadata(with: url) { metadata, error in
                if let error {
                    print("❌ Failed to fetch share metadata: \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                guard let metadata else {
                    print("❌ Failed to fetch share metadata: metadata is nil")
                    continuation.resume(returning: nil)
                    return
                }

                print("✅ Fetched share metadata")
                continuation.resume(returning: PendingShareInvite(metadata: metadata))
            }
        }
    }

    private func isICloudShareURL(_ url: URL) -> Bool {
        let hostContainsICloud = (url.host ?? "").localizedCaseInsensitiveContains("icloud.com")
        let path = url.path.lowercased()
        let pathContainsShare = path.contains("/share/") || path.hasPrefix("/share")
        return hostContainsICloud && pathContainsShare
    }
}
