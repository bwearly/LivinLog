//
//  CloudSharingView.swift
//  Livin Log
//

import SwiftUI
import CoreData
import CloudKit
import UIKit

struct CloudSharingView: UIViewControllerRepresentable {
    @Environment(\.managedObjectContext) private var viewContext

    let household: Household
    let persistentContainer: NSPersistentCloudKitContainer
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDone: onDone)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear

        DispatchQueue.main.async {
            Task { @MainActor in
                do {
                    // ✅ Re-fetch the object in THIS context (important)
                    guard let hh = try viewContext.existingObject(with: household.objectID) as? Household else {
                        throw NSError(
                            domain: "CloudSharingView",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Household could not be resolved before sharing."]
                        )
                    }

                    // Save any pending changes before sharing
                    if viewContext.hasChanges {
                        try viewContext.save()
                    }

                    let share = try await fetchOrCreateShare(for: hh)
                    let ckContainer = cloudKitContainer()

                    let controller = UICloudSharingController(share: share, container: ckContainer)
                    controller.availablePermissions = [.allowReadOnly, .allowReadWrite]
                    controller.delegate = context.coordinator

                    // ✅ CRITICAL: This fires when user taps ✅ / dismisses
                    controller.presentationController?.delegate = context.coordinator

                    host.present(controller, animated: true)
                } catch {
                    print("❌ Cloud share failed:", error)
                    context.coordinator.finish() // dismiss SwiftUI sheet even on failure
                }
            }
        }

        return host
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    // MARK: - CloudKit container

    private func cloudKitContainer() -> CKContainer {
        if let id = persistentContainer.persistentStoreDescriptions.first?
            .cloudKitContainerOptions?.containerIdentifier {
            return CKContainer(identifier: id)
        }
        return CKContainer.default()
    }

    // MARK: - Share logic

    private func fetchOrCreateShare(for household: Household) async throws -> CKShare {
        // 1) Try fetch existing share
        let sharesByID = try persistentContainer.fetchShares(matching: [household.objectID])
        if let existing = sharesByID[household.objectID] {
            return existing
        }

        // 2) Create a new share
        return try await withCheckedThrowingContinuation { continuation in
            persistentContainer.share([household], to: nil) { _, share, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let share else {
                    continuation.resume(throwing: NSError(
                        domain: "CloudSharing",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Share was nil."]
                    ))
                    return
                }

                // ✅ Invite-based sharing: do NOT set publicPermission
                share[CKShare.SystemFieldKey.title] =
                    (household.name ?? "Household") as CKRecordValue

                continuation.resume(returning: share)
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICloudSharingControllerDelegate, UIAdaptivePresentationControllerDelegate {
        private let onDone: () -> Void
        private var didFinish = false

        init(onDone: @escaping () -> Void) {
            self.onDone = onDone
        }

        func finish() {
            guard !didFinish else { return }
            didFinish = true
            DispatchQueue.main.async { self.onDone() }
        }

        // ✅ Fires whenever the sharing controller is dismissed (✅ button, swipe, etc.)
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finish()
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            print("❌ Failed to save share:", error)
            finish()
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            print("✅ Saved share.")
            finish()
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            print("🛑 Stopped sharing.")
            finish()
        }

        func itemTitle(for csc: UICloudSharingController) -> String? { nil }
    }
}
