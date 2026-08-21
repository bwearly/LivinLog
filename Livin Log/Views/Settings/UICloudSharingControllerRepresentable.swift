//
//  UICloudSharingControllerRepresentable.swift
//  Livin Log
//

import SwiftUI
import CoreData
import CloudKit
import UIKit

private struct PrepareShareWatchdogTimeoutError: LocalizedError {
    var errorDescription: String? {
        "Preparing the invite link is taking longer than expected. Check your connection and try again."
    }
}

/// Carries a `CKShare` across the `withThrowingTaskGroup` boundary in `prepareShare`.
/// `CKShare`'s own `Sendable` conformance isn't verified, so this box is used instead
/// of relying on it directly satisfying the task group's `Sendable` result constraint.
private struct PrepareShareResultBox: @unchecked Sendable {
    let share: CKShare
}

/// ✅ “Share via Messages” flow:
/// - Creates/updates the CKShare for the Household
/// - Sets publicPermission = .readWrite so anyone with the link can join
/// - Persists the updated share
/// - Presents the standard iOS share sheet (Messages) using share.url
struct CloudKitHouseholdSharingSheet: UIViewControllerRepresentable {
    let household: Household
    let onDone: () -> Void
    let onShareReady: (CKShare) -> Void
    let onError: (Error) -> Void

    private let persistentContainer = PersistenceController.shared.container

    func makeCoordinator() -> Coordinator {
        Coordinator(onDone: onDone, onShareReady: onShareReady, onError: onError)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear

        DispatchQueue.main.async {
            prepareShare { share, _, error in
                DispatchQueue.main.async {
                    if let error {
                        context.coordinator.onError(error)
                        context.coordinator.finish()
                        return
                    }

                    guard let share else {
                        context.coordinator.onError(NSError(
                            domain: "CloudKitHouseholdSharingSheet",
                            code: 999,
                            userInfo: [NSLocalizedDescriptionKey: "Share was nil."]
                        ))
                        context.coordinator.finish()
                        return
                    }

                    guard let shareURL = share.url else {
                        context.coordinator.onError(NSError(
                            domain: "CloudKitHouseholdSharingSheet",
                            code: 1000,
                            userInfo: [NSLocalizedDescriptionKey: "Share URL was nil. The share may not have been saved yet."]
                        ))
                        context.coordinator.finish()
                        return
                    }

                    print("✅ [CloudSharing] Share URL available; presenting share sheet")
                    context.coordinator.shareReady(share)

                    // ✅ Standard iOS share sheet (Messages shows up here)
                    let activity = UIActivityViewController(activityItems: [shareURL], applicationActivities: nil)

                    // iPad safety (doesn't hurt on iPhone)
                    activity.popoverPresentationController?.sourceView = host.view
                    activity.popoverPresentationController?.sourceRect = CGRect(
                        x: host.view.bounds.midX,
                        y: host.view.bounds.midY,
                        width: 1,
                        height: 1
                    )

                    activity.completionWithItemsHandler = { _, _, _, _ in
                        context.coordinator.finish()
                    }

                    host.present(activity, animated: true) {
                        print("ℹ️ [CloudSharing] Share sheet presented")
                    }
                }
            }
        }

        return host
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private func prepareShare(completion: @escaping (CKShare?, CKContainer?, Error?) -> Void) {
        let context = persistentContainer.viewContext

        func completeOnMain(_ share: CKShare?, _ container: CKContainer?, _ error: Error?) {
            DispatchQueue.main.async {
                completion(share, container, error)
            }
        }

        Task { @MainActor in
            do {
                guard let householdInContext = try context.existingObject(with: household.objectID) as? Household else {
                    completeOnMain(nil, self.cloudKitContainer(), NSError(
                        domain: "CloudKitHouseholdSharingSheet",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Household not found."]
                    ))
                    return
                }

                let watchdogAttemptID = UUID().uuidString.prefix(8)
                print("ℹ️ [CloudSharing] prepareShare starting fetchOrCreateShare (watchdog armed) attempt=\(watchdogAttemptID) at=\(ISO8601DateFormatter().string(from: Date()))")

                // Safety net only: this does not fix a stuck mirroring-delegate completion
                // handler, it just turns an indefinite spinner into a visible, user-facing
                // error after ~9s so the share sheet host is never left blank forever.
                // CKShare's Sendable conformance isn't verified against the SDK, so the
                // result is carried across the task group in an @unchecked Sendable box
                // rather than assuming CKShare itself satisfies the group's Sendable bound.
                let resultBox = try await withThrowingTaskGroup(of: PrepareShareResultBox.self) { group -> PrepareShareResultBox in
                    group.addTask { @MainActor in
                        let share = try await CloudSharing.fetchOrCreateShare(
                            for: householdInContext,
                            in: context,
                            persistentContainer: persistentContainer
                        )
                        return PrepareShareResultBox(share: share)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 9_000_000_000)
                        print("⏱️ [CloudSharing] prepareShare watchdog fired after 9s with no result attempt=\(watchdogAttemptID) at=\(ISO8601DateFormatter().string(from: Date()))")
                        throw PrepareShareWatchdogTimeoutError()
                    }

                    defer { group.cancelAll() }

                    guard let result = try await group.next() else {
                        throw PrepareShareWatchdogTimeoutError()
                    }
                    return result
                }
                let share = resultBox.share

                print("ℹ️ [CloudSharing] prepareShare fetchOrCreateShare returned before watchdog attempt=\(watchdogAttemptID) at=\(ISO8601DateFormatter().string(from: Date()))")

#if DEBUG
                debugPrintShareStatus(for: householdInContext, persistentContainer: persistentContainer)
#endif
                completeOnMain(share, self.cloudKitContainer(), nil)
            } catch {
                completeOnMain(nil, self.cloudKitContainer(), error)
            }
        }
    }

    private func cloudKitContainer() -> CKContainer {
        if let id = persistentContainer.persistentStoreDescriptions
            .first?
            .cloudKitContainerOptions?
            .containerIdentifier {
            return CKContainer(identifier: id)
        }
        return CKContainer.default()
    }

    final class Coordinator: NSObject {
        private let onDone: () -> Void
        private let onShareReady: (CKShare) -> Void
        let onError: (Error) -> Void
        private var finished = false
        private var reportedShareReady = false

        init(
            onDone: @escaping () -> Void,
            onShareReady: @escaping (CKShare) -> Void,
            onError: @escaping (Error) -> Void
        ) {
            self.onDone = onDone
            self.onShareReady = onShareReady
            self.onError = onError
        }

        func shareReady(_ share: CKShare) {
            guard !reportedShareReady else { return }
            reportedShareReady = true
            DispatchQueue.main.async { self.onShareReady(share) }
        }

        func finish() {
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { self.onDone() }
        }
    }
}

/// Presents Apple's native "people with access" management UI for an *existing* household
/// CKShare (constructed with `UICloudSharingController(share:container:)`, not the
/// preparation-handler initializer `CloudKitHouseholdSharingSheet` above uses to create one).
///
/// This exists specifically so leader-initiated member removal doesn't have to solve identity
/// correlation itself: this app has no stored mapping from a `HouseholdMembership`/`AppUser`
/// to the corresponding `CKShare.Participant` (CloudKit's `CKUserIdentity` isn't the same
/// identity system as this app's Sign in with Apple durable subject, and nothing persists a
/// link between them). Rather than guess a participant to remove by, e.g., matching display
/// names, this hands the owner off to CloudKit's own participant list, which already knows the
/// real identities and lets them pick the right person to remove.
struct CloudShareManagementSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            csc.share?[CKShare.SystemFieldKey.title] as? String
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            print("ℹ️ [CloudShareManagementSheet] share changes saved (e.g. a participant was removed)")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            print("ℹ️ [CloudShareManagementSheet] owner stopped sharing from the management sheet")
            DispatchQueue.main.async { self.onDismiss() }
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            print("❌ [CloudShareManagementSheet] failed to save share changes: \(error.localizedDescription)")
        }
    }
}
