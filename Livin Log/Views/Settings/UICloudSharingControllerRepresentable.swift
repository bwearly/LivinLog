//
//  UICloudSharingControllerRepresentable.swift
//  Livin Log
//

import SwiftUI
import CoreData
import CloudKit
import UIKit

/// Presents a share UI for a Household by generating/reusing a CKShare and then sharing its URL.
/// This avoids UICloudSharingController (which can appear blank depending on device capabilities / configuration).
struct CloudKitHouseholdSharingSheet: UIViewControllerRepresentable {
    let household: Household
    let onDone: () -> Void
    let onError: (Error) -> Void

    private let persistentContainer = PersistenceController.shared.container

    func makeCoordinator() -> Coordinator {
        Coordinator(onDone: onDone, onError: onError)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = UICloudSharingController { _, completion in
            prepareShare(completion: completion)
        }

        controller.availablePermissions = [.allowReadWrite]
        controller.delegate = context.coordinator

        let nav = UINavigationController(rootViewController: controller)
        nav.presentationController?.delegate = context.coordinator
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    private func prepareShare(completion: @escaping (CKShare?, CKContainer?, Error?) -> Void) {
        let context = persistentContainer.viewContext

        context.perform {
            do {
                guard let householdInContext = try context.existingObject(with: household.objectID) as? Household else {
                    let error = NSError(
                        domain: "CloudKitHouseholdSharingSheet",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Household not found."]
                    )
                    completion(nil, self.cloudKitContainer(), error)
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
                        completion(nil, self.cloudKitContainer(), error)
                        return
                    }

                    guard let share else {
                        let error = NSError(
                            domain: "CloudKitHouseholdSharingSheet",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Share was nil."]
                        )
                        completion(nil, self.cloudKitContainer(), error)
                        return
                    }

                    share[CKShare.SystemFieldKey.title] = (householdInContext.name ?? "Livin Log Household") as CKRecordValue
                    share.publicPermission = .readWrite

                    // TEMP DEBUG LOGGING
                    print("[CloudKitHouseholdSharingSheet] share.publicPermission=\(share.publicPermission.rawValue)")
                    if let shareURL = share.url {
                        print("[CloudKitHouseholdSharingSheet] share.url=\(shareURL.absoluteString)")
                    } else {
                        print("[CloudKitHouseholdSharingSheet] share.url=nil")
                    }

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
                        let error = NSError(
                            domain: "CloudKitHouseholdSharingSheet",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Could not resolve a persistent store to persist the share."]
                        )
                        completion(nil, self.cloudKitContainer(), error)
                        return
                    }

                    print("[CloudKitHouseholdSharingSheet] persisting updated share into storeURL=\(store.url?.absoluteString ?? "nil")")

                    self.persistentContainer.persistUpdatedShare(share, in: store) { _, persistError in
                        if let persistError {
                            completion(nil, self.cloudKitContainer(), persistError)
                            return
                        }

                        completion(share, self.cloudKitContainer(), nil)
                    }
                }
            } catch {
                completion(nil, self.cloudKitContainer(), error)
            }
        }
    }

    private func cloudKitContainer() -> CKContainer {
        if let containerIdentifier = persistentContainer
            .persistentStoreDescriptions
            .first?
            .cloudKitContainerOptions?
            .containerIdentifier {
            return CKContainer(identifier: containerIdentifier)
        }

        return CKContainer.default()
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate, UIAdaptivePresentationControllerDelegate {
        private let onDone: () -> Void
        private let onError: (Error) -> Void
        private var finished = false

        init(onDone: @escaping () -> Void, onError: @escaping (Error) -> Void) {
            self.onDone = onDone
            self.onError = onError
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { self.onDone() }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finish()
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            finish()
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            finish()
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            onError(error)
            finish()
        }

        // Required by UICloudSharingControllerDelegate to provide a title for the shared item
        func itemTitle(for csc: UICloudSharingController) -> String? {
            // Provide a sensible default title for the share sheet
            return "Livin Log Household"
        }
    }
}

