import SwiftUI
import CloudKit

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

    private var inviteTitle: String {
        let ownerName = pendingInvite.metadata.ownerIdentity.nameComponents?.formatted() ?? "Someone"
        let householdTitle = (pendingInvite.metadata.share?[CKShare.SystemFieldKey.title] as? String) ?? "a household"
        return "\(ownerName) invited you to join \(householdTitle)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(inviteTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)

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

                    Button("Accept") {
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

                Task {
                    await onAccepted()
                }
            }
        }
    }
}
