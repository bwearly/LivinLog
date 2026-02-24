//
//  UICloudSharingControllerRepresentable.swift
//  Livin Log
//

import SwiftUI
import CoreData
import CloudKit
import UIKit
import MessageUI

struct CloudKitHouseholdSharingSheet: UIViewControllerRepresentable {
    private static let alwaysCreateNewShare = false

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
        Coordinator(onDone: onDone, onError: onError)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        print("ℹ️ Share routes availability canSendText=\(MFMessageComposeViewController.canSendText()) canSendMail=\(MFMailComposeViewController.canSendMail())")

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
        let watchdogSeconds: TimeInterval = 8
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
            let onMain = Thread.isMainThread
            print("ℹ️ prepareShare.finish share=\(share == nil ? "nil" : "non-nil") error=\(error == nil ? "nil" : "non-nil") callbackThread=\(onMain ? "main" : "background")")
            if let nsError = error as NSError? {
                print("ℹ️ prepareShare.finish NSError domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)")
            }
            if let ckError = error as? CKError {
                print("ℹ️ prepareShare.finish CKError code=\(ckError.code.rawValue) (\(ckError.code)) userInfo=\(ckError.userInfo)")
            }
            DispatchQueue.main.async {
                completion(share, cloudKitContainer, error)
            }
        }

        print("ℹ️ Entering prepareShare for household objectID=\(household.objectID) isTemporary=\(household.objectID.isTemporaryID)")
        print("ℹ️ prepareShare containerIdentifier=\(configuredContainerIdentifier)")

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + watchdogSeconds) {
            let timeoutError = NSError(
                domain: "CloudKitHouseholdSharingSheet",
                code: 99,
                userInfo: [NSLocalizedDescriptionKey: "Share preparation timed out after \(Int(watchdogSeconds))s."]
            )
            print("⏱️ prepareShare watchdog timed out after \(Int(watchdogSeconds))s")
            finish(nil, timeoutError)
        }

        context.perform {
            do {
                guard let householdInContext = try context.existingObject(with: household.objectID) as? Household else {
                    let error = NSError(
                        domain: "CloudKitHouseholdSharingSheet",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Household not found."]
                    )
                    print("❌ prepareShare could not locate household in context.")
                    finish(nil, error)
                    return
                }

                print("ℹ️ prepareShare before persistence checks objectID=\(householdInContext.objectID) isTemporary=\(householdInContext.objectID.isTemporaryID) context.hasChanges=\(context.hasChanges)")

                // ✅ Ensure permanent objectID.
                if householdInContext.objectID.isTemporaryID {
                    print("ℹ️ prepareShare obtaining permanent objectID before sharing")
                    try context.obtainPermanentIDs(for: [householdInContext])
                    print("ℹ️ prepareShare obtained permanent objectID=\(householdInContext.objectID) isTemporary=\(householdInContext.objectID.isTemporaryID)")
                }

                if context.hasChanges {
                    print("ℹ️ Context has changes before sharing. Saving context.")
                    try context.save()
                    print("✅ prepareShare saved context prior to share")
                }

                print("ℹ️ prepareShare after persistence checks objectID=\(householdInContext.objectID) isTemporary=\(householdInContext.objectID.isTemporaryID) context.hasChanges=\(context.hasChanges)")

                let createShare: () -> Void = {
                    print("ℹ️ Creating new CKShare for household.")
                    persistentContainer.share([householdInContext], to: nil) { _, share, _, error in
                        if let error {
                            print("❌ Failed creating CKShare in preparation handler: \(error)")
                            let nsError = error as NSError
                            print("❌ CKShare creation NSError domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)")
                            if let ckError = error as? CKError {
                                print("❌ CKShare creation CKError code=\(ckError.code.rawValue) (\(ckError.code)) userInfo=\(ckError.userInfo)")
                            }
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
                        share.publicPermission = .readWrite
                        print("ℹ️ Prepared new CKShare recordID=\(share.recordID.recordName) publicPermission=\(share.publicPermission.rawValue) url=\(share.url?.absoluteString ?? \"nil\") containerIdentifier=\(configuredContainerIdentifier)")
                        print("✅ Prepared new CKShare for UICloudSharingController: \(share.recordID.recordName)")
                        finish(share, nil)
                    }
                }

                if Self.alwaysCreateNewShare {
                    print("ℹ️ alwaysCreateNewShare=true, bypassing existing share lookup.")
                    createShare()
                    return
                }

                persistentContainer.fetchShares(matching: [householdInContext.objectID]) { result in
                    switch result {
                    case .failure(let error):
                        print("❌ Failed fetching existing CKShare, falling back to create: \(error)")
                        let nsError = error as NSError
                        print("❌ fetchShares NSError domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)")
                        if let ckError = error as? CKError {
                            print("❌ fetchShares CKError code=\(ckError.code.rawValue) (\(ckError.code)) userInfo=\(ckError.userInfo)")
                        }
                        createShare()

                    case .success(let sharesByID):
                        let keys = sharesByID.keys.map { $0.uriRepresentation().absoluteString }
                        let containsObjectID = sharesByID.keys.contains(householdInContext.objectID)
                        let existingShare = sharesByID[householdInContext.objectID] ?? nil
                        print("ℹ️ fetchShares success keys=\(keys)")
                        print("ℹ️ fetchShares containsObjectID=\(containsObjectID) valueForObjectID=\(existingShare == nil ? "nil" : "non-nil")")
                        if let existingShare = sharesByID[householdInContext.objectID] {
                            let shareTitle = householdTitle(from: householdInContext)
                            existingShare[CKShare.SystemFieldKey.title] = shareTitle as CKRecordValue
                            existingShare.publicPermission = .readWrite
                            print("ℹ️ Reusing existing CKShare recordID=\(existingShare.recordID.recordName) publicPermission=\(existingShare.publicPermission.rawValue) url=\(existingShare.url?.absoluteString ?? \"nil\") containerIdentifier=\(configuredContainerIdentifier)")
                            print("ℹ️ Reusing existing CKShare for household recordID=\(existingShare.recordID.recordName)")
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

        // Optional: if you suspect a hang, this helps you notice in logs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            finishLock.lock()
            let finished = didFinish
            finishLock.unlock()
            if !finished {
                print("⚠️ prepareShare still not finished after 6 seconds (possible hang in share fetch/create).")
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
            let share = csc.share
            print("✅ UICloudSharingController didSaveShare recordID=\(share?.recordID.recordName ?? \"nil\") publicPermission=\(share?.publicPermission.rawValue.description ?? \"nil\") url=\(share?.url?.absoluteString ?? \"nil\")")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            print("🛑 UICloudSharingController stopped sharing.")
            finish()
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            let share = csc.share
            print("❌ UICloudSharingController failedToSaveShareWithError error=\(error) recordID=\(share?.recordID.recordName ?? \"nil\") publicPermission=\(share?.publicPermission.rawValue.description ?? \"nil\") url=\(share?.url?.absoluteString ?? \"nil\")")
            onError(error)
            finish()
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Livin Log Household"
        }
    }
}
