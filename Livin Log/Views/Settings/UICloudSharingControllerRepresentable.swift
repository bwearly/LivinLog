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

        context.perform {
            do {
                guard let householdInContext = try context.existingObject(with: household.objectID) as? Household else {
                    throw NSError(domain: "CloudKitHouseholdSharingSheet", code: 1, userInfo: [NSLocalizedDescriptionKey: "Household not found."])
                }

                if householdInContext.objectID.isTemporaryID {
                    try context.obtainPermanentIDs(for: [householdInContext])
                }

                if let existingShare = try? persistentContainer.fetchShares(matching: [householdInContext.objectID])[householdInContext.objectID] {
                    let shareTitle = householdTitle(from: householdInContext)
                    existingShare[CKShare.SystemFieldKey.title] = shareTitle as CKRecordValue
                    print("ℹ️ Reusing existing CKShare for household: \(existingShare.recordID.recordName)")
                    completion(existingShare, cloudKitContainer, nil)
                    return
                }

                persistentContainer.share([householdInContext], to: nil) { _, share, _, error in
                    if let error {
                        print("❌ Failed creating CKShare in preparation handler: \(error)")
                        completion(nil, nil, error)
                        return
                    }

                    guard let share else {
                        let error = NSError(domain: "CloudKitHouseholdSharingSheet", code: 2, userInfo: [NSLocalizedDescriptionKey: "Share was nil."])
                        completion(nil, nil, error)
                        return
                    }

                    let shareTitle = householdTitle(from: householdInContext)
                    share[CKShare.SystemFieldKey.title] = shareTitle as CKRecordValue

                    print("✅ Prepared CKShare for UICloudSharingController: \(share.recordID.recordName)")
                    completion(share, cloudKitContainer, nil)
                }
            } catch {
                print("❌ Failed preparing share in UICloudSharingController preparation handler: \(error)")
                completion(nil, nil, error)
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
