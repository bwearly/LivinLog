//
//  HouseholdInviteLinkView.swift
//  Livin Log
//

import SwiftUI
import CoreData
import UIKit

struct HouseholdInviteLinkView: UIViewControllerRepresentable {
    @Environment(\.managedObjectContext) private var viewContext

    let household: Household
    let onDone: () -> Void
    let onError: (String) -> Void

    private let persistentContainer: NSPersistentCloudKitContainer = PersistenceController.shared.container

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear

        DispatchQueue.main.async {
            Task { @MainActor in
                do {
                    let hh = try viewContext.existingObject(with: household.objectID) as! Household

                    if viewContext.hasChanges {
                        try viewContext.save()
                    }

                    _ = try await CloudSharing.fetchOrCreateShare(
                        for: hh,
                        in: viewContext,
                        persistentContainer: persistentContainer
                    )

                    guard let url = try await CloudSharing.fetchShareURLWithRetry(
                        for: hh.objectID,
                        persistentContainer: persistentContainer
                    ) else {
                        CloudSharing.saveLastShareError("Invite link not ready yet. Try again in a moment.")
                        onError("Invite link not ready yet. Try again in a moment.")
                        return
                    }

                    CloudSharing.saveLastShareStatus("Invite link ready")
                    CloudSharing.saveLastShareError(nil)

                    let message = "Join my Livin Log household: \(hh.name ?? "Household")"

                    let activity = UIActivityViewController(
                        activityItems: [message, url],
                        applicationActivities: nil
                    )

                    // Optional: set a subject for Mail
                    activity.setValue("Livin Log Household Invite", forKey: "subject")

                    activity.completionWithItemsHandler = { _, _, _, _ in
                        onDone()
                    }

                    host.present(activity, animated: true)
                } catch {
                    CloudSharing.saveLastShareError("Invite failed: \(error.localizedDescription)")
                    onError("Invite failed: \(error.localizedDescription)")
                }
            }
        }

        return host
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
