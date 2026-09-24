//
//  ActivityShareSheet.swift
//  Livin Log
//
//  Phase 3b: the plain system share sheet used for household invites (share.oneTimeURL(for:) +
//  a short message) -- distinct from UICloudSharingController, which the Phase 3b plan
//  deliberately doesn't use for invites (see HouseholdShareManager's header comment). Mirrors
//  the completion-handler pattern already used by
//  Views/Settings/UICloudSharingControllerRepresentable.swift's CloudKitHouseholdSharingSheet.

import SwiftUI
import UIKit

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    /// `true` only if the user actually picked an activity (not cancel/dismiss) -- callers use
    /// this to decide whether to stamp `invitedAt` (see AppState.markInvited(_:)).
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onComplete(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
