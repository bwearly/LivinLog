import SwiftUI
import CloudKit

struct PasteInviteLinkSheet: View {
    let onInviteReady: (PendingShareInvite) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var inviteURLText = ""
    @State private var isFetching = false
    @State private var errorMessage: String?

    private let container = CKContainer(identifier: "iCloud.com.blakeearly.livinlog")

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste your iCloud share link to join a household.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("https://icloud.com/share/...", text: $inviteURLText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if isFetching {
                    ProgressView("Loading invite…")
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Join Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isFetching)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        fetchMetadata()
                    }
                    .disabled(isFetching || inviteURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func fetchMetadata() {
        errorMessage = nil

        guard let cleanedURL = normalizedInviteURL(from: inviteURLText) else {
            errorMessage = "Enter a valid iCloud share link."
            return
        }

        isFetching = true
        container.fetchShareMetadata(with: cleanedURL) { metadata, error in
            DispatchQueue.main.async {
                isFetching = false

                if let error {
                    errorMessage = "Could not load invite: \(error.localizedDescription)"
                    return
                }

                guard let metadata else {
                    errorMessage = "Could not load invite metadata."
                    return
                }

                onInviteReady(PendingShareInvite(metadata: metadata))
                dismiss()
            }
        }
    }

    private func normalizedInviteURL(from rawText: String) -> URL? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard var components = URLComponents(string: trimmed) else { return nil }
        components.fragment = nil

        guard let url = components.url else { return nil }
        guard isValidICloudShareURL(url) else { return nil }

        return url
    }

    private func isValidICloudShareURL(_ url: URL) -> Bool {
        let hostContainsICloud = (url.host ?? "").localizedCaseInsensitiveContains("icloud.com")
        let path = url.path.lowercased()
        let pathContainsShare = path.contains("/share/") || path.hasPrefix("/share")
        return hostContainsICloud && pathContainsShare
    }
}
