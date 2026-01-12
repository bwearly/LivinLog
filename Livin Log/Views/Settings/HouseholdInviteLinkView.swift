//
//  HouseholdInviteLinkView.swift
//  Keeply
//

import SwiftUI
import CoreData
import CloudKit
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

                    let share = try await fetchOrCreateShare(for: hh)

                    // ✅ Share the URL (this gives you the normal share options)
                    guard let url = share.url else {
                        onError("Invite link not ready yet. Try again in a moment.")
                        return
                    }

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
                    onError("Invite failed: \(error.localizedDescription)")
                }
            }
        }

        return host
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private func fetchOrCreateShare(for household: Household) async throws -> CKShare {
        let sharesByID = try persistentContainer.fetchShares(matching: [household.objectID])
        if let existing = sharesByID[household.objectID] {
            return existing
        }

        return try await withCheckedThrowingContinuation { continuation in
            persistentContainer.share([household], to: nil) { _, share, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let share else {
                    continuation.resume(throwing: NSError(
                        domain: "HouseholdInvite",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Share was nil."]
                    ))
                    return
                }

                share[CKShare.SystemFieldKey.title] = (household.name ?? "Household") as CKRecordValue
                continuation.resume(returning: share)
            }
        }
    }
}
