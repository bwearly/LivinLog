//
//  UICloudSharingControllerRepresentable.swift
//  Livin Log
//

import SwiftUI
import CoreData
import CloudKit
import UIKit

/// ✅ “Share via Messages” flow:
/// - Creates/updates the CKShare for the Household
/// - Sets publicPermission = .readWrite so anyone with the link can join
/// - Persists the updated share
/// - Presents the standard iOS share sheet (Messages) using share.url
struct CloudKitHouseholdSharingSheet: UIViewControllerRepresentable {
    let household: Household
    let onDone: () -> Void
    let onError: (Error) -> Void

    private let persistentContainer = PersistenceController.shared.container

    func makeCoordinator() -> Coordinator {
        Coordinator(onDone: onDone, onError: onError)
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

                    host.present(activity, animated: true)
                }
            }
        }

        return host
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private func prepareShare(completion: @escaping (CKShare?, CKContainer?, Error?) -> Void) {
        let context = persistentContainer.viewContext

        // helper to guarantee main-thread completion
        func completeOnMain(_ share: CKShare?, _ container: CKContainer?, _ error: Error?) {
            DispatchQueue.main.async {
                completion(share, container, error)
            }
        }

        context.perform {
            do {
                guard let householdInContext = try context.existingObject(with: household.objectID) as? Household else {
                    completeOnMain(nil, self.cloudKitContainer(), NSError(
                        domain: "CloudKitHouseholdSharingSheet",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Household not found."]
                    ))
                    return
                }

                if householdInContext.objectID.isTemporaryID {
                    try context.obtainPermanentIDs(for: [householdInContext])
                }

                if context.hasChanges {
                    try context.save()
                }

                self.persistentContainer.share([householdInContext], to: nil) { _, share, _, error in
                    if let error {
                        completeOnMain(nil, self.cloudKitContainer(), error)
                        return
                    }

                    guard let share else {
                        completeOnMain(nil, self.cloudKitContainer(), NSError(
                            domain: "CloudKitHouseholdSharingSheet",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Share was nil."]
                        ))
                        return
                    }

                    // ✅ Configure share for link-based join + read/write
                    share[CKShare.SystemFieldKey.title] =
                        (householdInContext.name ?? "Livin Log Household") as CKRecordValue
                    share.publicPermission = .readWrite

                    // Resolve private store (URL-based API)
                    let privateStoreURL = self.persistentContainer.persistentStoreDescriptions
                        .first(where: { $0.cloudKitContainerOptions?.databaseScope == .private })?
                        .url

                    let storeForShare: NSPersistentStore? = {
                        if let url = privateStoreURL {
                            return self.persistentContainer.persistentStoreCoordinator.persistentStore(for: url)
                        }
                        return self.persistentContainer.persistentStoreCoordinator.persistentStores.first
                    }()

                    guard let store = storeForShare else {
                        completeOnMain(nil, self.cloudKitContainer(), NSError(
                            domain: "CloudKitHouseholdSharingSheet",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Could not resolve a persistent store to persist the share."]
                        ))
                        return
                    }

                    self.persistentContainer.persistUpdatedShare(share, in: store) { _, persistError in
                        if let persistError {
                            completeOnMain(nil, self.cloudKitContainer(), persistError)
                            return
                        }

                        completeOnMain(share, self.cloudKitContainer(), nil)
                    }
                }
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
        let onError: (Error) -> Void
        private var finished = false

        init(onDone: @escaping () -> Void, onError: @escaping (Error) -> Void) {
            self.onDone = onDone
            self.onError = onError
        }

        func finish() {
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { self.onDone() }
        }
    }
}
