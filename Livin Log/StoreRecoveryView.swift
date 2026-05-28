import SwiftUI

struct StoreRecoveryView: View {
    let error: PersistenceLoadError

    @State private var debugResetMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Couldn’t Open Saved Data", systemImage: "exclamationmark.triangle.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.orange)

                    Text("Livin Log could not open its local iCloud data store on this device.")
                        .font(.headline)

                    Text("Your iCloud data may still be safe. This usually means the local copy on this device could not be opened or migrated.")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Try these steps:")
                            .font(.headline)
                        Text("• Close Livin Log and reopen it.")
                        Text("• Confirm iCloud Drive and CloudKit are available for this Apple ID.")
                        Text("• Make sure the device has network access and enough storage.")
                        Text("• If this continues, contact support and include the diagnostic details below.")
                    }

                    diagnosticsSection

                    #if DEBUG
                    debugResetSection
                    #endif
                }
                .padding()
            }
            .navigationTitle("Data Recovery")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics")
                .font(.headline)
            Text("Store: \(error.storeURL?.lastPathComponent ?? "Unknown")")
            Text("Configuration: \(error.configuration)")
            Text("Error: \(error.underlyingDomain) \(error.underlyingCode)")
            Text(error.message)
                .textSelection(.enabled)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    #if DEBUG
    private var debugResetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEBUG ONLY")
                .font(.headline)
                .foregroundStyle(.red)
            Text("This removes local development SQLite store files from this simulator/device. Do not use this as a production recovery path.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                do {
                    try PersistenceController.resetDevelopmentStores()
                    debugResetMessage = "Development stores removed. Close and reopen the app."
                } catch {
                    debugResetMessage = "Reset failed: \(error.localizedDescription)"
                }
            } label: {
                Text("Reset Development Stores")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if let debugResetMessage {
                Text(debugResetMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    #endif
}
