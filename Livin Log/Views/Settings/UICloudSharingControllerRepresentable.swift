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

    private var configuredContainerIdentifier: String {
        persistentContainer.persistentStoreDescriptions.first?.cloudKitContainerOptions?.containerIdentifier
        ?? "iCloud.com.blakeearly.livinlog"
    }

    private var cloudKitContainer: CKContainer {
        CKContainer(identifier: configuredContainerIdentifier)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            household: household,
            persistentContainer: persistentContainer,
            cloudKitContainer: cloudKitContainer,
            onDone: onDone,
            onError: onError
        )
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = SharePresenterViewController()
        vc.onViewDidAppear = {
            context.coordinator.presentShareFlow(from: vc)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    // MARK: - UIKit Presenter VC

    private final class SharePresenterViewController: UIViewController {
        var onViewDidAppear: (() -> Void)?
        private var hasPresented = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !hasPresented else { return }
            hasPresented = true
            onViewDidAppear?()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        private let household: Household
        private let persistentContainer: NSPersistentCloudKitContainer
        private let cloudKitContainer: CKContainer
        private let onDone: () -> Void
        private let onError: (Error) -> Void

        private let finishLock = NSLock()
        private var didFinish = false

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

        func presentShareFlow(from presentingVC: UIViewController) {
            // If you want, you can keep this watchdog. It helps avoid “silent blank” hangs.
            let watchdogSeconds: TimeInterval = 10
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + watchdogSeconds) { [weak self] in
                guard let self else { return }
                self.finishOnce(
                    error: NSError(
                        domain: "CloudKitHouseholdSharingSheet",
                        code: 99,
                        userInfo: [NSLocalizedDescriptionKey: "Share flow timed out after \(Int(watchdogSeconds))s."]
                    )
                )
            }

            prepareShare { [weak self] share in
                guard let self else { return }

                guard let url = share.url else {
                    self.finishOnce(
                        error: NSError(
                            domain: "CloudKitHouseholdSharingSheet",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "CloudKit share URL was nil (share may not be saved yet)."]
                        )
                    )
                    return
                }

                DispatchQueue.main.async {
                    // Present a normal iOS share sheet with the exact household’s CloudKit share URL.
                    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)

                    // iPad safety
                    if let pop = activity.popoverPresentationController {
                        pop.sourceView = presentingVC.view
                        pop.sourceRect = CGRect(
                            x: presentingVC.view.bounds.midX,
                            y: presentingVC.view.bounds.midY,
                            width: 1,
                            height: 1
                        )
                        pop.permittedArrowDirections = []
                    }

                    activity.completionWithItemsHandler = { [weak self] _, _, _, _ in
                        self?.finishOnceSuccess()
                    }

                    presentingVC.present(activity, animated: true)
                }
            }
        }

        // MARK: - Share Preparation

        private func prepareShare(completion: @escaping (CKShare) -> Void) {
            let context = persistentContainer.viewContext

            context.perform {
                do {
                    guard let householdInContext = try context.existingObject(with: self.household.objectID) as? Household else {
                        throw NSError(
                            domain: "CloudKitHouseholdSharingSheet",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Household not found in Core Data context."]
                        )
                    }

                    // Ensure permanent IDs + save
                    if householdInContext.objectID.isTemporaryID {
                        try context.obtainPermanentIDs(for: [householdInContext])
                    }
                    if context.hasChanges {
                        try context.save()
                    }

                    // IMPORTANT: use the synchronous/throwing fetchShares API (this avoids the “extra trailing closure” error).
                    let sharesByID = try self.persistentContainer.fetchShares(matching: [householdInContext.objectID])

                    if let existingShare = sharesByID[householdInContext.objectID] {
                        self.applyShareMetadata(existingShare, household: householdInContext)
                        completion(existingShare)
                        return
                    }

                    // Create a new share
                    self.persistentContainer.share([householdInContext], to: nil) { _, share, _, error in
                        if let error {
                            self.finishOnce(error: error)
                            return
                        }
                        guard let share else {
                            self.finishOnce(
                                error: NSError(
                                    domain: "CloudKitHouseholdSharingSheet",
                                    code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "Share creation returned nil share."]
                                )
                            )
                            return
                        }

                        self.applyShareMetadata(share, household: householdInContext)
                        completion(share)
                    }
                } catch {
                    self.finishOnce(error: error)
                }
            }
        }

        private func applyShareMetadata(_ share: CKShare, household: Household) {
            let title = (household.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let shareTitle = title.isEmpty ? "Livin Log Household" : title
            share[CKShare.SystemFieldKey.title] = shareTitle as CKRecordValue

            // If you want a URL that can be shared broadly, a public permission helps CloudKit generate/maintain the URL.
            // You can choose `.readOnly` if you want recipients to not be able to edit.
            share.publicPermission = .readWrite
        }

        // MARK: - Finish helpers

        private func finishOnceSuccess() {
            finishLock.lock()
            defer { finishLock.unlock() }
            guard !didFinish else { return }
            didFinish = true
            DispatchQueue.main.async { self.onDone() }
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
