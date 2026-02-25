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
                    completion(share, self.cloudKitContainer(), nil)
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

        init(
            household: Household,
            persistentContainer: NSPersistentCloudKitContainer,
            cloudKitContainer: CKContainer,
            onDone: @escaping () -> Void,
            onError: @escaping (Error) -> Void
        ) {
            self.household = household
            self.persistentContainer = persistentContainer
            self.cloudKitContainer = cloudKitContainer
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

        private func finishOnce(error: Error) {
            finishLock.lock()
            defer { finishLock.unlock() }
            guard !didFinish else { return }
            didFinish = true
            DispatchQueue.main.async {
                self.onError(error)
                self.onDone()
            }
        }
    }
}
