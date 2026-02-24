//
//  UICloudSharingControllerRepresentable.swift
//  Livin Log
//

import SwiftUI
import CoreData
import CloudKit
import UIKit

struct CloudKitHouseholdSharingSheet: UIViewControllerRepresentable {
    let household: Household
    let onDone: () -> Void
    let onError: (Error) -> Void

    private let persistentContainer = PersistenceController.shared.container
    private let cloudKitContainer = CKContainer(identifier: "iCloud.com.blakeearly.livinlog")

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
        let alwaysCreateNewShare = false
        let finishLock = NSLock()
        var didFinish = false

        func finish(_ share: CKShare?, _ error: Error?) {
            finishLock.lock()
            defer { finishLock.unlock() }

            guard !didFinish else {
                print("⚠️ prepareShare attempted to call completion more than once. Ignoring duplicate callback.")
                return
            }

            didFinish = true
            DispatchQueue.main.async {
                completion(share, cloudKitContainer, error)
            }
        }

        print("ℹ️ Entering prepareShare for household objectID: \(household.objectID)")

        context.perform {
            do {
                guard let householdInContext = try context.existingObject(with: household.objectID) as? Household else {
                    let error = NSError(domain: "CloudKitHouseholdSharingSheet", code: 1, userInfo: [NSLocalizedDescriptionKey: "Household not found."])
                    print("❌ prepareShare could not locate household in context.")
                    finish(nil, error)
                    return
                }

                if context.hasChanges {
                    print("ℹ️ Context has changes before sharing. Saving context.")
                    try context.save()
                }

                if householdInContext.objectID.isTemporaryID {
                    try context.obtainPermanentIDs(for: [householdInContext])
                    try context.save()
                    print("✅ Obtained permanent objectID for household: \(householdInContext.objectID)")
                }

                let createShare: () -> Void = {
                    print("ℹ️ Creating new CKShare for household.")
                    persistentContainer.share([householdInContext], to: nil) { _, share, _, error in
                        if let error {
                            print("❌ Failed creating CKShare in preparation handler: \(error)")
                            finish(nil, error)
                            return
                        }

                        guard let share else {
                            let nilShareError = NSError(domain: "CloudKitHouseholdSharingSheet", code: 2, userInfo: [NSLocalizedDescriptionKey: "Share was nil."])
                            print("❌ CKShare creation callback returned nil share without error.")
                            finish(nil, nilShareError)
                            return
                        }

                        let shareTitle = householdTitle(from: householdInContext)
                        share[CKShare.SystemFieldKey.title] = shareTitle as CKRecordValue
                        print("✅ Prepared new CKShare for UICloudSharingController: \(share.recordID.recordName)")
                        finish(share, nil)
                    }
                }

                if alwaysCreateNewShare {
                    print("ℹ️ alwaysCreateNewShare=true, bypassing existing share lookup.")
                    createShare()
                    return
                }

                persistentContainer.fetchShares(matching: [householdInContext.objectID]) { result in
                    switch result {
                    case .failure(let error):
                        print("❌ Failed fetching existing CKShare, falling back to create: \(error)")
                        createShare()

                    case .success(let sharesByID):
                        if let existingShare = sharesByID[householdInContext.objectID] {
                            let shareTitle = householdTitle(from: householdInContext)
                            existingShare[CKShare.SystemFieldKey.title] = shareTitle as CKRecordValue
                            print("ℹ️ Reusing existing CKShare for household: \(existingShare.recordID.recordName)")
                            finish(existingShare, nil)
                        } else {
                            print("ℹ️ No existing CKShare found. Creating one.")
                            createShare()
                        }
                    }
                }
            } catch {
                print("❌ Failed preparing share in UICloudSharingController preparation handler: \(error)")
                finish(nil, error)
            }
        }
    }

    private func householdTitle(from household: Household) -> String {
        let trimmed = household.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Livin Log Household" : trimmed
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate, UIAdaptivePresentationControllerDelegate {
        private let onDone: () -> Void
        private let onError: (Error) -> Void
        private var didFinish = false

        init(onDone: @escaping () -> Void, onError: @escaping (Error) -> Void) {
            self.onDone = onDone
            self.onError = onError
        }

        private func finish() {
            guard !didFinish else { return }
            didFinish = true
            DispatchQueue.main.async { self.onDone() }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finish()
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            print("✅ UICloudSharingController saved share.")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            print("🛑 UICloudSharingController stopped sharing.")
            finish()
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            print("❌ UICloudSharingController failed to save share: \(error)")
            onError(error)
            finish()
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Livin Log Household"
        }
    }
}
