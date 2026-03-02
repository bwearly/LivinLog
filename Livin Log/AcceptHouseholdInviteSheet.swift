import SwiftUI
import CloudKit
import CoreData

struct PendingShareInvite: Identifiable {
    let id = UUID()
    let metadata: CKShare.Metadata
}

struct AcceptHouseholdInviteSheet: View {
    let pendingInvite: PendingShareInvite
    let onAccepted: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isAccepting = false
    @State private var errorMessage: String?

    /// True if the currently selected household (if any) lives in the PRIVATE store.
    /// We resolve the store by comparing the objectID's persistentStore to PersistenceController.shared.privateStore.
    private var hasActivePrivateHousehold: Bool {
        let ctx = PersistenceController.shared.container.viewContext
        let (selectedHousehold, _) = SelectionStore.load(context: ctx)
        guard let selectedHousehold else { return false }

        // ✅ Correct way to map objectID -> NSPersistentStore in your environment
        guard let store = selectedHousehold.objectID.persistentStore else { return false }

        return store == PersistenceController.shared.privateStore
    }

    private var inviteTitle: String {
        let ownerName = pendingInvite.metadata.ownerIdentity.nameComponents?.formatted() ?? "Someone"
        let householdTitle = (pendingInvite.metadata.share[CKShare.SystemFieldKey.title] as? String) ?? "a household"
        return "\(ownerName) invited you to join \(householdTitle)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(inviteTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if hasActivePrivateHousehold {
                    Text("You already have a household. Accepting will switch your active household.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button("Not Now") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isAccepting)

                    Button(hasActivePrivateHousehold ? "Switch & Join" : "Accept") {
                        acceptInvite()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAccepting)
                }

                if isAccepting {
                    ProgressView("Accepting invite…")
                }
            }
            .padding()
            .navigationTitle("Household Invite")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(280)])
        .interactiveDismissDisabled(isAccepting)
    }

    private func acceptInvite() {
        isAccepting = true
        errorMessage = nil

        let persistence = PersistenceController.shared
        persistence.container.acceptShareInvitations(
            from: [pendingInvite.metadata],
            into: persistence.sharedStore
        ) { _, error in
            DispatchQueue.main.async {
                if let error {
                    errorMessage = "Could not accept invite: \(error.localizedDescription)"
                    isAccepting = false
                    return
                }

                isAccepting = false
                dismiss()
                NotificationCenter.default.post(name: .didAcceptCloudKitShare, object: nil)
                print("✅ Invite accepted; posted didAcceptCloudKitShare; rerunning app state")

                Task { await onAccepted() }
            }
        }
    }
}
