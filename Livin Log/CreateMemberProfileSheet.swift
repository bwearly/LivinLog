import SwiftUI
import CoreData

struct CreateMemberProfileSheet: View {
    let household: Household
    let onCreated: (HouseholdMember) -> Void

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var displayName = ""
    @State private var selectedExistingMemberID: NSManagedObjectID?
    @State private var isSaving = false
    @State private var errorText: String?

    private var availableMembers: [HouseholdMember] {
        IdentityStore.unclaimedMembers(for: household, context: context)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if !availableMembers.isEmpty {
                    Text("Claim your existing profile")
                        .font(.headline)

                    Picker("Member", selection: $selectedExistingMemberID) {
                        Text("Select").tag(Optional<NSManagedObjectID>.none)
                        ForEach(availableMembers, id: \.objectID) { member in
                            Text(member.displayName ?? "Unnamed").tag(Optional(member.objectID))
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Claim Selected Profile") {
                        claimSelectedMember()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving || selectedExistingMemberID == nil)
                }

                Divider()

                Text("Or create a new profile")
                    .font(.headline)

                TextField("Your name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSaving)

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    createMember()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || trimmedName.isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("Your Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func claimSelectedMember() {
        errorText = nil
        isSaving = true
        defer { isSaving = false }

        guard let selectedExistingMemberID,
              let selectedMember = try? context.existingObject(with: selectedExistingMemberID) as? HouseholdMember else {
            errorText = "Please select a profile to claim."
            return
        }

        do {
            let role = household.members?.count ?? 0 <= 1 ? "leader" : "member"
            try appState.claim(member: selectedMember, role: role)
            onCreated(selectedMember)
            dismiss()
        } catch {
            context.rollback()
            errorText = error.localizedDescription
        }
    }

    private func createMember() {
        errorText = nil
        isSaving = true
        defer { isSaving = false }

        do {
            let role = availableMembers.isEmpty && ((household.members?.count ?? 0) == 0) ? "leader" : "member"
            let member = try appState.createAndClaimMember(named: trimmedName, in: household, role: role)
            SelectionStore.save(household: household, member: member)
            SelectionStore.saveDeviceMember(member, for: household)
            onCreated(member)
            dismiss()
        } catch {
            context.rollback()
            errorText = error.localizedDescription
        }
    }
}
