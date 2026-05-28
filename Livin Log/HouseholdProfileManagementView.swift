import SwiftUI
import CoreData

struct HouseholdProfileManagementView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState

    let memberships: [HouseholdMembership]
    let onPicked: ((HouseholdMembership) -> Void)?
    let showsPickerTitle: Bool

    @State private var pendingCleanup: CleanupCandidate?
    @State private var cleanupError: String?
    @State private var isCleaningUp = false
    @State private var hiddenMembershipIDs: Set<NSManagedObjectID> = []

    init(
        memberships: [HouseholdMembership],
        showsPickerTitle: Bool = false,
        onPicked: ((HouseholdMembership) -> Void)? = nil
    ) {
        self.memberships = memberships
        self.showsPickerTitle = showsPickerTitle
        self.onPicked = onPicked
    }

    var body: some View {
        List {
            if showsPickerTitle {
                Section {
                    Text("Choose the household/profile you want to use. Metadata below helps distinguish duplicate-looking rows.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Profiles") {
                let visibleMemberships = memberships.filter { !hiddenMembershipIDs.contains($0.objectID) }
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
            cleanupTitle,
            isPresented: Binding(get: { pendingCleanup != nil }, set: { if !$0 { pendingCleanup = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingCleanup {
                Button(pendingCleanup.buttonTitle, role: .destructive) {
                    performCleanup(pendingCleanup)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingCleanup?.message ?? "")
        }
        .alert("Profile Cleanup Failed", isPresented: Binding(get: { cleanupError != nil }, set: { if !$0 { cleanupError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cleanupError ?? "The selected profile could not be cleaned up.")
        }
    }

    @ViewBuilder
    private func profileRow(for membership: HouseholdMembership) -> some View {
        let summary = ProfileSummary(membership: membership, currentMembership: appState.currentMembership, currentHousehold: appState.household, currentMember: appState.member)
        VStack(alignment: .leading, spacing: 10) {
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
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(summary.householdName)
                                .font(.headline)
                            if summary.isCurrent {
                                Text("Current")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(summary.memberName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(summary.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
#if DEBUG
                        Text(summary.debugScope)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
#endif
                    }
                    Spacer(minLength: 8)
                }
            }
            .buttonStyle(.plain)
            .disabled(onPicked == nil || isCleaningUp)

            if let cleanup = cleanupCandidate(for: membership, summary: summary) {
                Button(role: .destructive) {
                    pendingCleanup = cleanup
                } label: {
                    Label(cleanup.buttonTitle, systemImage: cleanup.systemImage)
                        .font(.caption.weight(.semibold))
                }
                .disabled(isCleaningUp)
            } else if summary.isCurrent {
                Text("Switch to another profile before deleting or leaving this one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if cleanupBlockedReason(for: membership) != nil {
                Text(cleanupBlockedReason(for: membership) ?? "Cleanup unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var cleanupTitle: String {
        pendingCleanup?.title ?? "Clean Up Profile?"
    }

    private func cleanupCandidate(for membership: HouseholdMembership, summary: ProfileSummary) -> CleanupCandidate? {
        guard !summary.isCurrent else { return nil }
        guard let household = membership.household else { return nil }
        guard let store = household.objectID.persistentStore else { return nil }

        if store == PersistenceController.shared.privateStore {
            guard isProvenOwner(of: household, via: membership) else { return nil }
            return CleanupCandidate(
                membership: membership,
                kind: .deletePrivateHousehold,
                title: "Delete \(summary.householdName)?",
                message: "This deletes this private duplicate household and its local app data from your account. This cannot be undone.",
                buttonTitle: "Delete Household",
                systemImage: "trash"
            )
        }

        if store == PersistenceController.shared.sharedStore {
            return CleanupCandidate(
                membership: membership,
                kind: .leaveSharedHousehold,
                title: "Leave \(summary.householdName)?",
                message: "This removes your local membership/selection for this shared household. It does not delete the owner's household data.",
                buttonTitle: "Leave Household",
                systemImage: "rectangle.portrait.and.arrow.right"
            )
        }

        return nil
    }

    private func cleanupBlockedReason(for membership: HouseholdMembership) -> String? {
        guard let household = membership.household else { return "Cleanup unavailable: household could not be resolved." }
        guard let store = household.objectID.persistentStore else { return "Cleanup unavailable: store could not be resolved." }
        if store == PersistenceController.shared.privateStore, !isProvenOwner(of: household, via: membership) {
            return "Delete unavailable: ownership could not be proven for this private household."
        }
        return nil
    }

    private func isProvenOwner(of household: Household, via membership: HouseholdMembership) -> Bool {
        guard let appUser = appState.appUser,
              let durableId = IdentityStore.durableUserId(for: appUser) else { return false }
        let role = (membership.role ?? "").lowercased()
        let createdBy = household.value(forKey: "createdByAppUserId") as? String
        return (role == "leader" || role == "owner") && createdBy == durableId
    }

    private func performCleanup(_ candidate: CleanupCandidate) {
        cleanupError = nil
        isCleaningUp = true

        do {
            switch candidate.kind {
            case .deletePrivateHousehold:
                try deletePrivateHousehold(candidate.membership)
            case .leaveSharedHousehold:
                try leaveSharedHousehold(candidate.membership)
            }

            hiddenMembershipIDs.insert(candidate.membership.objectID)
            pendingCleanup = nil
            SelectionStore.clearAll()
            debugCleanup("cleared cached selection after \(candidate.kind.logLabel)")
            Task { @MainActor in
                await appState.start(callSite: "HouseholdProfileManagementView.cleanup")
                isCleaningUp = false
            }
        } catch {
            context.rollback()
            isCleaningUp = false
            cleanupError = error.localizedDescription
            debugCleanup("cleanup failed: \(error)")
        }
    }

    private func deletePrivateHousehold(_ membership: HouseholdMembership) throws {
        guard let householdID = membership.household?.objectID else {
            throw cleanupError("Household could not be resolved.")
        }
        guard let scopedHousehold = try context.existingObject(with: householdID) as? Household else {
            throw cleanupError("Household no longer exists.")
        }
        guard scopedHousehold.objectID.persistentStore == PersistenceController.shared.privateStore else {
            throw cleanupError("Only private owner households can be deleted here.")
        }
        guard let scopedMembership = try context.existingObject(with: membership.objectID) as? HouseholdMembership,
              isProvenOwner(of: scopedHousehold, via: scopedMembership) else {
            throw cleanupError("Livin Log could not prove that you own this household, so it was not deleted.")
        }

        debugCleanup("deleting private household id=\(scopedHousehold.objectID.uriRepresentation().absoluteString)")
        context.delete(scopedHousehold)
        try context.save()
    }

    private func leaveSharedHousehold(_ membership: HouseholdMembership) throws {
        guard let scopedMembership = try context.existingObject(with: membership.objectID) as? HouseholdMembership else {
            throw cleanupError("Membership no longer exists.")
        }
        guard let household = scopedMembership.household else {
            throw cleanupError("Shared household could not be resolved.")
        }
        guard household.objectID.persistentStore == PersistenceController.shared.sharedStore else {
            throw cleanupError("Only shared households can be left here.")
        }

        // Safety: do not delete or mutate shared Core Data records here. Deleting
        // objects in the shared store could propagate through CloudKit. Leaving is
        // implemented as local selection/auto-pick suppression only.
        SharedHouseholdLeaveStore.markLeft(household)
        debugCleanup("locally left shared membership id=\(scopedMembership.objectID.uriRepresentation().absoluteString)")
    }

    private func cleanupError(_ message: String) -> NSError {
        NSError(domain: "HouseholdProfileCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func debugCleanup(_ message: String) {
#if DEBUG
        print("🧹 [ProfileCleanup] \(message)")
#endif
    }
}

private struct ProfileSummary {
    let householdName: String
    let memberName: String
    let subtitle: String
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

        let roleText = Self.displayRole(membership.role)
        let created = membership.joinedAt ?? membership.createdAt ?? member?.createdAt ?? household?.createdAt
        let createdText = created.map { "Created \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Created date unknown"
        let lastSeen = membership.appUser?.value(forKey: "lastSeenAt") as? Date
        let lastSeenText = lastSeen.map { "Last active \($0.formatted(date: .abbreviated, time: .omitted))" }
        subtitle = ([createdText, roleText] + [lastSeenText].compactMap { $0 }).joined(separator: " • ")

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

private struct CleanupCandidate: Identifiable {
    enum Kind {
        case deletePrivateHousehold
        case leaveSharedHousehold

        var logLabel: String {
            switch self {
            case .deletePrivateHousehold: return "delete private household"
            case .leaveSharedHousehold: return "leave shared household"
            }
        }
    }

    let id = UUID()
    let membership: HouseholdMembership
    let kind: Kind
    let title: String
    let message: String
    let buttonTitle: String
    let systemImage: String
}
