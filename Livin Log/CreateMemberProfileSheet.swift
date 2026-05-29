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
    @State private var pendingMemberDelete: HouseholdMember?
    @State private var isSaving = false
    @State private var errorText: String?

    private var availableMembers: [HouseholdMember] {
        IdentityStore.unclaimedMembers(for: household, context: context)
    }

    var body: some View {
        NavigationStack {
            List {
                if !availableMembers.isEmpty {
                    Section {
                        Text("Choose an existing profile, or swipe left on an unwanted duplicate to delete it before continuing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        ForEach(availableMembers, id: \.objectID) { member in
                            existingMemberRow(member)
                        }
                    } header: {
                        Text("Claim your existing profile")
                    }

                    Section {
                        Button("Claim Selected Profile") {
                            claimSelectedMember()
                        }
                        .disabled(isSaving || selectedExistingMemberID == nil)
                    }
                }

                Section {
                    TextField("Your name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSaving)

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
                } header: {
                    Text("Or create a new profile")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Your Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog(
            pendingMemberDelete.map { "Delete \($0.displayName ?? "Profile")?" } ?? "Delete Profile?",
            isPresented: Binding(get: { pendingMemberDelete != nil }, set: { if !$0 { pendingMemberDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingMemberDelete {
                Button("Delete Profile", role: .destructive) {
                    deleteUnclaimedMember(pendingMemberDelete)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only this unclaimed profile. Household data such as movies, books, TV shows, puzzles, quotes, and dates will stay in the household.")
        }
    }

    private func existingMemberRow(_ member: HouseholdMember) -> some View {
        let availability = memberDeleteAvailability(member)
        return Button {
            selectedExistingMemberID = member.objectID
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedExistingMemberID == member.objectID ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundStyle(selectedExistingMemberID == member.objectID ? Color.accentColor : Color.secondary)
                    .font(.title3)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(member.displayName ?? "Unnamed Profile")
                        .font(.headline)

                    Label(household.name ?? "Household", systemImage: "house")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(member.createdAt.map { "Created \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Created date unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if case .blocked(let reason) = availability {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            switch availability {
            case .allowed:
                Button(role: .destructive) {
                    pendingMemberDelete = member
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isSaving)
            case .blocked:
                Button(role: .destructive) {} label: {
                    Label("Can't Delete", systemImage: "trash.slash")
                }
                .disabled(true)
            }
        }
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func memberDeleteAvailability(_ member: HouseholdMember) -> MemberDeleteAvailability {
        guard household.objectID.persistentStore == PersistenceController.shared.privateStore else {
            return .blocked("Shared household profiles are managed by the household owner.")
        }

        guard availableMembers.count > 1 || (household.members?.count ?? 0) > 1 else {
            return .blocked("At least one usable profile must remain.")
        }

        let feedbacks = (member.value(forKey: "feedbacks") as? NSSet)?.count ?? 0
        let bookEntries = (member.value(forKey: "bookEntries") as? NSSet)?.count ?? 0
        guard feedbacks == 0 && bookEntries == 0 else {
            return .blocked("This profile is connected to household entries, so it is preserved.")
        }

        return .allowed
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

    private func deleteUnclaimedMember(_ member: HouseholdMember) {
        errorText = nil
        isSaving = true
        defer { isSaving = false }

        do {
            guard case .allowed = memberDeleteAvailability(member) else {
                throw NSError(domain: "CreateMemberProfileSheet", code: 1, userInfo: [NSLocalizedDescriptionKey: "This profile cannot be deleted safely."])
            }
            guard let scopedMember = try context.existingObject(with: member.objectID) as? HouseholdMember else {
                throw NSError(domain: "CreateMemberProfileSheet", code: 2, userInfo: [NSLocalizedDescriptionKey: "Profile no longer exists."])
            }

            if selectedExistingMemberID == scopedMember.objectID {
                selectedExistingMemberID = nil
            }
            context.delete(scopedMember)
            try context.save()
            pendingMemberDelete = nil
            print("🧹 [ProfileDeletion] deleted unclaimed profile id=\(member.objectID.uriRepresentation().absoluteString)")
        } catch {
            context.rollback()
            errorText = "Could not delete profile: \(error.localizedDescription)"
            print("❌ [ProfileDeletion] failed to delete unclaimed profile: \(error)")
        }
    }
}

private enum MemberDeleteAvailability {
    case allowed
    case blocked(String)
}
