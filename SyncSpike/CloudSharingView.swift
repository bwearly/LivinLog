//
//  CloudSharingView.swift
//  SyncSpike
//
//  SwiftUI wrapper for UICloudSharingController, presenting an already-saved
//  CKShare (UICloudSharingController(share:container:)). The spec asked to
//  note ShareLink as a comparison rather than build it too: ShareLink (iOS 16+)
//  can share a CKShare's URL as plain content, but it doesn't give you the
//  native "who has access / remove participant" management UI that
//  UICloudSharingController does -- for a household-membership feature you
//  want that management UI, so UICloudSharingController is the better fit
//  and is the only one built here.

import CloudKit
import SwiftUI
import UIKit

struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPublic]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            SpikeLogger.error(SpikeLogger.share, "UICloudSharingController failedToSaveShareWithError: \(String(describing: error))")
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Livin Log Spike Household"
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            SpikeLogger.log(SpikeLogger.share, "UICloudSharingController didSaveShare")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            SpikeLogger.log(SpikeLogger.share, "UICloudSharingController didStopSharing")
        }
    }
}
