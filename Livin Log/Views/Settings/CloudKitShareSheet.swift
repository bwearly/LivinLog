//
//  CloudKitShareSheet.swift
//  Keeply
//

import SwiftUI
import CoreData
import CloudKit
import UIKit

struct CloudKitShareSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let onDone: () -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDone: onDone, onError: onError)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        print("✅ CloudKitShareSheet makeUIViewController (DIRECT SHARE INIT)")

        let csc = UICloudSharingController(share: share, container: container)
        csc.availablePermissions = [.allowReadOnly, .allowReadWrite]
        csc.delegate = context.coordinator

        // Helps avoid “blank” due to layout/lifecycle weirdness
        csc.loadViewIfNeeded()

        let nav = UINavigationController(rootViewController: csc)
        nav.navigationBar.isHidden = true
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let onDone: () -> Void
        private let onError: (Error) -> Void
        private var didFinish = false

        init(onDone: @escaping () -> Void, onError: @escaping (Error) -> Void) {
            self.onDone = onDone
            self.onError = onError
        }

        private func finishOnce() {
            guard !didFinish else { return }
            didFinish = true
            DispatchQueue.main.async { self.onDone() }
        }

        // ✅ Don’t dismiss here — user may still be interacting with Add People UI.
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            print("✅ CloudKit share saved.")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            print("🛑 CloudKit sharing stopped.")
            finishOnce()
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            print("❌ CloudKit share failed:", error)
            onError(error)
            finishOnce()
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Keeply Household"
        }
    }
}
