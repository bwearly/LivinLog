import SwiftUI
import CoreData

struct HouseholdProfileManagementView: View {
    @Environment(\.managedObjectContext) private var context

    let memberships: [HouseholdMembership]
    let onPicked: ((HouseholdMembership) -> Void)?
    let showsPickerTitle: Bool
    let currentMembership: HouseholdMembership?
    let currentHousehold: Household?
    let currentMember: HouseholdMember?
    let currentAppUser: AppUser?
    let onCleanupCompleted: (() async -> Void)?

    @State private var pendingDeletion: ProfileDeletionCandidate?
    @State private var deletionError: String?
    @State private var isDeleting = false
    @State private var hiddenMembershipIDs: Set<NSManagedObjectID> = []

    init(
        memberships: [HouseholdMembership],
        showsPickerTitle: Bool = false,
        currentMembership: HouseholdMembership? = nil,
        currentHousehold: Household? = nil,
        currentMember: HouseholdMember? = nil,
        currentAppUser: AppUser? = nil,
        onPicked: ((HouseholdMembership) -> Void)? = nil,
        onCleanupCompleted: (() async -> Void)? = nil
    ) {
        self.memberships = memberships
        self.showsPickerTitle = showsPickerTitle
        self.currentMembership = currentMembership
        self.currentHousehold = currentHousehold
        self.currentMember = currentMember
        self.currentAppUser = currentAppUser
        self.onPicked = onPicked
        self.onCleanupCompleted = onCleanupCompleted
    }

    private var visibleMemberships: [HouseholdMembership] {
        memberships.filter { !hiddenMembershipIDs.contains($0.objectID) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(showsPickerTitle ? "Choose your profile" : "Manage duplicate profiles")
                        .font(.headline)
                    Text("Swipe left on an extra profile to delete only that profile or membership. Household content stays in the household.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section("Profiles") {
                if visibleMemberships.isEmpty {
                    ContentUnavailableView("No profiles found", systemImage: "person.crop.circle.badge.questionmark")
                } else {
                    ForEach(visibleMemberships, id: \.objectID) { membership in
                        profileRow(for: membership)
                    }
                }
            }
        }
        .navigationTitle(showsPickerTitle ? "Choose Profile" : "Profiles & Households")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pendingDeletion?.title ?? "Delete Profile?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button(pendingDeletion.buttonTitle, role: .destructive) {
                    performProfileDeletion(pendingDeletion)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingDeletion?.message ?? "")
        }
        .alert("Profile Delete Failed", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "The selected profile could not be deleted.")
        }
    }

    @ViewBuilder
    private func profileRow(for membership: HouseholdMembership) -> some View {
        let summary = ProfileSummary(membership: membership, currentMembership: currentMembership, currentHousehold: currentHousehold, currentMember: currentMember)
        let availability = deleteAvailability(for: membership, summary: summary)

        Button {
            onPicked?(membership)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(summary.isCurrent ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    Image(systemName: summary.isCurrent ? "checkmark.circle.fill" : "person.crop.circle")
                        .foregroundStyle(summary.isCurrent ? Color.accentColor : Color.secondary)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(summary.memberName)
                            .font(.headline)
                        if summary.isCurrent {
                            Text("Current")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }
                    }

                    Label(summary.householdName, systemImage: "house")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Text(summary.roleText)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        Text(summary.createdText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let lastSeenText = summary.lastSeenText {
                        Text(lastSeenText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if case .blocked(let reason) = availability {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

#if DEBUG
                    Text(summary.debugScope)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
#endif
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            switch availability {
            case .allowed(let candidate):
                Button(role: .destructive) {
                    pendingDeletion = candidate
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isDeleting)
            case .blocked:
                Button(role: .destructive) {} label: {
                    Label("Can't Delete", systemImage: "trash.slash")
                }
                .disabled(true)
            }
        }
    }

    private func deleteAvailability(for membership: HouseholdMembership, summary: ProfileSummary) -> ProfileDeleteAvailability {
        guard !summary.isCurrent else {
            return .blocked("Switch to another profile before deleting this current profile.")
        }

        guard visibleMemberships.count > 1 else {
            return .blocked("At least one usable profile must remain.")
        }

        guard currentAppUser != nil else {
            return .blocked("Sign in is required before deleting profiles.")
        }

        guard let household = membership.household else {
            return .blocked("Delete unavailable: household could not be resolved.")
        }

        guard membership.memberProfile != nil else {
            return .blocked("Delete unavailable: member profile could not be resolved.")
        }

        guard let store = household.objectID.persistentStore else {
            return .blocked("Delete unavailable: store could not be resolved.")
        }

        guard store == PersistenceController.shared.privateStore else {
            return .blocked("Shared household profiles are managed by the household owner. Leaving a shared household is separate from deleting a profile.")
        }

        return .allowed(ProfileDeletionCandidate(
            membership: membership,
            title: "Delete \(summary.memberName)?",
            message: "This removes the selected profile from \(summary.householdName). Household data such as movies, books, TV shows, puzzles, quotes, and dates will stay in the household. This cannot be undone.",
            buttonTitle: "Delete Profile"
        ))
    }

    private func performProfileDeletion(_ candidate: ProfileDeletionCandidate) {
        deletionError = nil
        isDeleting = true

        do {
            try deleteProfile(candidate.membership)
            hiddenMembershipIDs.insert(candidate.membership.objectID)
            pendingDeletion = nil
            debugProfileDeletion("deleted profile membership id=\(candidate.membership.objectID.uriRepresentation().absoluteString)")

            if let onCleanupCompleted {
                Task { @MainActor in
                    await onCleanupCompleted()
                    isDeleting = false
                }
            } else {
                isDeleting = false
            }
        } catch {
            context.rollback()
            isDeleting = false
            deletionError = error.localizedDescription
            debugProfileDeletion("delete failed: \(error)")
        }
    }

    private func deleteProfile(_ membership: HouseholdMembership) throws {
        guard let currentAppUser else {
            throw profileDeletionError("Sign in is required before deleting profiles.")
        }

        let activeMemberships = IdentityStore.memberships(for: currentAppUser, context: context)
            .filter { !hiddenMembershipIDs.contains($0.objectID) }
        guard activeMemberships.count > 1 else {
            throw profileDeletionError("At least one usable profile must remain.")
        }

        guard membership.objectID != currentMembership?.objectID else {
            throw profileDeletionError("Switch to another profile before deleting the current profile.")
        }

        guard let scopedMembership = try context.existingObject(with: membership.objectID) as? HouseholdMembership else {
            throw profileDeletionError("Profile no longer exists.")
        }

        guard scopedMembership.objectID != currentMembership?.objectID else {
            throw profileDeletionError("Switch to another profile before deleting the current profile.")
        }

        guard let household = scopedMembership.household else {
            throw profileDeletionError("Household could not be resolved.")
        }

        guard household.objectID.persistentStore == PersistenceController.shared.privateStore else {
            throw profileDeletionError("Shared household profiles are managed by the household owner.")
        }

        let member = scopedMembership.memberProfile
        let shouldDeleteMember = try member.map { try canSafelyDeleteMember($0, excluding: scopedMembership) } ?? false

        scopedMembership.status = "deleted"
        scopedMembership.memberProfile = nil
        scopedMembership.household = nil
        scopedMembership.appUser = nil
        context.delete(scopedMembership)

        if let member, shouldDeleteMember {
            debugProfileDeletion("deleting unused member profile id=\(member.objectID.uriRepresentation().absoluteString)")
            context.delete(member)
        } else if let member, let durableId = IdentityStore.durableUserId(for: currentAppUser) {
            let claimedBy = member.value(forKey: "claimedByAppUserId") as? String
            if claimedBy == durableId {
                member.setValue(nil, forKey: "claimedByAppUserId")
            }
        }

        try context.save()
    }

    private func canSafelyDeleteMember(_ member: HouseholdMember, excluding membership: HouseholdMembership) throws -> Bool {
        guard let household = member.household else { return false }

        let memberCountRequest = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        memberCountRequest.predicate = NSPredicate(format: "household == %@", household)
        let householdMemberCount = try context.count(for: memberCountRequest)
        guard householdMemberCount > 1 else { return false }

        let memberMemberships = (member.value(forKey: "memberships") as? NSSet)?.compactMap { $0 as? HouseholdMembership } ?? []
        let hasOtherActiveMembership = memberMemberships.contains { candidate in
            candidate.objectID != membership.objectID && candidate.status == "active"
        }
        guard !hasOtherActiveMembership else { return false }

        let feedbacks = (member.value(forKey: "feedbacks") as? NSSet)?.count ?? 0
        let bookEntries = (member.value(forKey: "bookEntries") as? NSSet)?.count ?? 0
        return feedbacks == 0 && bookEntries == 0
    }

    private func profileDeletionError(_ message: String) -> NSError {
        NSError(domain: "HouseholdProfileDeletion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func debugProfileDeletion(_ message: String) {
        print("🧹 [ProfileDeletion] \(message)")
    }
}

private enum ProfileDeleteAvailability {
    case allowed(ProfileDeletionCandidate)
    case blocked(String)
}

private struct ProfileSummary {
    let householdName: String
    let memberName: String
    let roleText: String
    let createdText: String
    let lastSeenText: String?
    let debugScope: String
    let isCurrent: Bool

    init(membership: HouseholdMembership, currentMembership: HouseholdMembership?, currentHousehold: Household?, currentMember: HouseholdMember?) {
        let household = membership.household
        let member = membership.memberProfile
        householdName = household?.name ?? "Household"
        memberName = member?.displayName ?? "Member"
        isCurrent = membership.objectID == currentMembership?.objectID || (
            household?.objectID == currentHousehold?.objectID &&
            member?.objectID == currentMember?.objectID
        )

        roleText = Self.displayRole(membership.role)
        let created = membership.joinedAt ?? membership.createdAt ?? member?.createdAt ?? household?.createdAt
        createdText = created.map { "Created \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Created date unknown"
        let lastSeen = membership.appUser?.value(forKey: "lastSeenAt") as? Date
        lastSeenText = lastSeen.map { "Last active \($0.formatted(date: .abbreviated, time: .omitted))" }

        let scope: String
        if household?.objectID.persistentStore == PersistenceController.shared.privateStore {
            scope = "private"
        } else if household?.objectID.persistentStore == PersistenceController.shared.sharedStore {
            scope = "shared"
        } else {
            scope = "unknown-store"
        }
        debugScope = "scope: \(scope) • household: \(household?.objectID.uriRepresentation().lastPathComponent ?? "unknown")"
    }

    private static func displayRole(_ role: String?) -> String {
        let normalized = (role ?? "member").lowercased()
        switch normalized {
        case "leader", "owner": return "Owner"
        default: return "Member"
        }
    }
}

private struct ProfileDeletionCandidate: Identifiable {
    let id = UUID()
    let membership: HouseholdMembership
    let title: String
    let message: String
    let buttonTitle: String
}
