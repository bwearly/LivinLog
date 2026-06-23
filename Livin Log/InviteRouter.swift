import Foundation
import CloudKit

final class InviteRouter {
    private let container: CKContainer

    init(containerIdentifier: String = "iCloud.com.blakeearly.livinlog") {
        container = CKContainer(identifier: containerIdentifier)
    }

    func pendingInvite(from url: URL) async -> PendingShareInvite? {
        // ✅ Normalize: remove fragment (#...) which often breaks metadata fetch.
        // CloudKit share links are code/token based; we do not match invitees by email, so Apple private relay email cannot block lookup here.
        let normalized = Self.stripFragment(url)
        print("🔗 [PendingInvite] lookup url=\(normalized.absoluteString) lookupMode=cloudKitShareURL store=sharedCloudKit emailMatching=false codeBased=true")

        guard isICloudShareURL(normalized) else {
            print("ℹ️ Not an iCloud share URL: \(normalized.absoluteString)")
            return nil
        }

        return await withCheckedContinuation { continuation in
            container.fetchShareMetadata(with: normalized) { metadata, error in
                if let error {
                    print("❌ [PendingInvite] share metadata lookup failed reason=fetchShareMetadataError url=\(normalized.absoluteString) error=\(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }

                guard let metadata else {
                    print("❌ [PendingInvite] share metadata lookup failed reason=nilMetadata url=\(normalized.absoluteString)")
                    continuation.resume(returning: nil)
                    return
                }

                print("✅ [PendingInvite] fetched share metadata url=\(normalized.absoluteString)")
                continuation.resume(returning: PendingShareInvite(metadata: metadata, sourceURL: normalized))
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
