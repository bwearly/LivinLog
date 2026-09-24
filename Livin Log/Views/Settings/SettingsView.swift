//
//  SettingsView.swift
//  Livin Log
//

import SwiftUI
import CoreData
import CloudKit
import MessageUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState

    @Binding var household: Household?
    @Binding var member: HouseholdMember?

    @State private var errorText: String?
    @State private var shareErrorText: String?
    @State private var showShareTechnicalDetails = false

    @State private var householdName = ""
    @State private var myName = ""

    @State private var isSharing = false

    @State private var share: CKShare?
    @State private var accountStatus: CKAccountStatus = .couldNotDetermine
    @State private var accountStatusMessage: String?
    @State private var lastCloudKitError: String?

    @AppStorage("ll_notify_enabled") private var notificationsEnabled = false
    @State private var showNotificationsDeniedAlert = false
    @State private var showConfirmDeleteAll = false

    @AppStorage(CloudSharing.lastShareErrorDefaultsKey) private var persistedLastShareError = ""
    @AppStorage(CloudSharing.lastShareStatusDefaultsKey) private var persistedLastShareStatus = ""

    /// nil until `loadAccountStatus()` returns -- keeps SyncStatusRow from flashing
    /// "iCloud unavailable" before the check has actually run.
    @State private var loadedAccountStatus: CKAccountStatus?

    @State private var householdNameDraft = ""
    @FocusState private var isHouseholdNameFocused: Bool
    @State private var showingAddMember = false

    @State private var showingLeaveConfirm = false
    @State private var isLeaving = false
    @State private var showingDeleteSheet = false
    @State private var deleteOtherMemberNames: [String] = []
    @State private var actionErrorText: String?

    private let persistentContainer = PersistenceController.shared.container

    var body: some View {
        Form {
            // Settings cleanup: householdSection, joinHouseholdSection, membersSection,
            // profilesSection, and the sharing issue/success banners are disabled, not deleted --
            // kept below, no longer shown.
            householdOverviewSection
            youSection
            notificationsSection
            syncSection
            aboutSection

            if household != nil {
                dangerZoneSection
            }

#if DEBUG
            developerDiagnosticsSection
            advancedSection
#endif

            if let errorText {
                Section {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
#if DEBUG
            print("Developer Diagnostics row available")
#endif
            if let hh = household { ensureDefaultMemberExists(in: hh) }
            reloadShareStatus()
            loadAccountStatus()
            householdNameDraft = household?.name ?? ""
        }
        .onChange(of: household?.objectID) { _, _ in
            if let hh = household { ensureDefaultMemberExists(in: hh) }
            reloadShareStatus()
            householdNameDraft = household?.name ?? ""
        }
        .onChange(of: household?.name) { _, newName in
            // Pick up a rename synced in from another device, unless mid-edit here.
            if !isHouseholdNameFocused { householdNameDraft = newName ?? "" }
        }
        .onChange(of: isHouseholdNameFocused) { _, focused in
            if !focused { commitHouseholdRename() }
        }
        .onDisappear {
            // Covers closing Settings mid-edit, where focus loss isn't guaranteed to fire first.
            commitHouseholdRename()
        }
        .sheet(isPresented: $showingAddMember) {
            if let household {
                AddMemberSheet(household: household) { _ in }
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showingDeleteSheet) {
            DeleteHouseholdSheet(
                householdName: household?.name ?? "Household",
                otherLinkedMemberNames: deleteOtherMemberNames
            ) {
                do {
                    try await appState.deleteHousehold()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        }
        .confirmationDialog(
            "Leave \(household?.name ?? "Household")?",
            isPresented: $showingLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave Household", role: .destructive) { performLeave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll lose access to this household on all your devices. Your past ratings stay in the household. To come back, the leader will need to invite you again.")
        }
        .alert("Couldn’t Complete", isPresented: Binding(get: { actionErrorText != nil }, set: { if !$0 { actionErrorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionErrorText ?? "")
        }
        .alert("Delete All Data?", isPresented: $showConfirmDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete & Restart", role: .destructive) {
                deleteAllDataAndRestart()
            }
        } message: {
            Text("This will delete local household data on this device and reset your selection. Shared iCloud data for other members may still exist.")
        }

        .alert("Notifications Disabled", isPresented: $showNotificationsDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Notifications are currently disabled for Livin Log. Go to Notifications → Open iPhone Settings to enable them.")
        }
    }

    // MARK: - Top-level Sections (User-facing)

    private var householdOverviewSection: some View {
        Section {
            if let household {
                if appState.isCurrentHouseholdOwner {
                    TextField("Household name", text: $householdNameDraft)
                        .font(.headline)
                        .focused($isHouseholdNameFocused)
                        .submitLabel(.done)
                        .onSubmit { isHouseholdNameFocused = false }
                } else {
                    HouseholdNameText(household: household)
                }

                MembersRosterSection(household: household)

                Button {
                    showingAddMember = true
                } label: {
                    Label("Add Member", systemImage: "person.badge.plus")
                }
            }
        } header: {
            Text("Household")
        } footer: {
            if household != nil, appState.isCurrentHouseholdOwner {
                Text("Tap the name to rename your household.")
            }
        }
    }

    private var youSection: some View {
        Section("You") {
            if let me = appState.member {
                NavigationLink {
                    EditProfileView(member: me)
                } label: {
                    ProfileRowLabel(member: me)
                }
            }
        }
    }

    private var syncSection: some View {
        Section("iCloud & Sync") {
            SyncStatusRow(accountStatus: loadedAccountStatus)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersionText)
            Text("To join another household, open the invite link you were sent.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var dangerZoneSection: some View {
        Section {
            if appState.isCurrentHouseholdOwner {
                Button("Delete Household", role: .destructive) {
                    deleteOtherMemberNames = appState.otherLinkedMembers().compactMap(\.displayName)
                    showingDeleteSheet = true
                }
            } else {
                Button(role: .destructive) {
                    showingLeaveConfirm = true
                } label: {
                    HStack {
                        Text("Leave Household")
                        if isLeaving {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isLeaving)
            }
        } header: {
            Text("Danger Zone")
                .foregroundStyle(.red)
        } footer: {
            Text(appState.isCurrentHouseholdOwner
                 ? "Deleting removes the household and everything in it for every member."
                 : "Leaving removes this household from your devices. The household itself stays for everyone else.")
        }
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // Settings cleanup: disabled, not deleted -- no longer shown (see body). Its "Create
    // Household" branch was unreachable anyway: Settings is only presented on `.main`.
    private var householdSection: some View {
        Section("Household") {
            if let household {
                VStack(alignment: .leading, spacing: 6) {
                    Text(household.name ?? "Household")
                        .font(.headline)
                    Text("Shared household syncs through iCloud.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } else {
                Text("Create a household to begin.")
                    .foregroundStyle(.secondary)

                TextField("Household name", text: $householdName)
                TextField("Your name (optional)", text: $myName)

                Button("Create Household") {
                    createHousehold()
                }
                .disabled(householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // Settings cleanup: disabled, not deleted -- its note now lives in the About section.
    private var joinHouseholdSection: some View {
        Section("Join Household") {
            Text("To join a household, open the invite link you were sent.")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            NavigationLink {
                NotificationsSettingsView(
                    context: context,
                    household: household,
                    showNotificationsDeniedAlert: $showNotificationsDeniedAlert
                )
            } label: {
                HStack {
                    Label("Notifications", systemImage: "bell.badge")
                    Spacer()
                    Text(notificationsEnabled ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // Settings cleanup: disabled, not deleted -- MembersRosterSection now renders inside
    // householdOverviewSection.
    private var membersSection: some View {
        Section("Members") {
            if let household {
                // Reactive: @FetchRequest re-runs automatically when a member's row (e.g. a
                // just-accepted invitee's HouseholdMember) merges in via CloudKit import, instead
                // of needing a manual re-fetch trigger. See MembersRosterSection.
                MembersRosterSection(household: household)
            } else {
                Text("Create a household to add members.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var profilesSection: some View {
        Section("Profiles & Households") {
            NavigationLink {
                HouseholdProfileManagementView(
                    memberships: currentMemberships(),
                    currentMembership: appState.currentMembership,
                    currentHousehold: appState.household,
                    currentMember: appState.member,
                    currentAppUser: appState.appUser,
                    onPicked: { membership in
                        appState.selectMembership(membership)
                    },
                    onCleanupCompleted: { await appState.start(callSite: "SettingsView.profileCleanup") }
                )
            } label: {
                Label("Manage Households & Profiles", systemImage: "house.and.flag")
            }
            Text("Tap a profile to switch your active household. Swipe left to leave or delete a duplicate. Household content stays in the household.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // Settings cleanup: the sharing issue/success banners below are disabled, not deleted. They
    // read CloudSharing's persisted status keys, which only the old UICloudSharingController
    // flow wrote, so they could only ever show stale values now.
    private var hasSharingIssue: Bool {
        if let shareErrorText, !shareErrorText.isEmpty { return true }
        if !persistedLastShareError.isEmpty { return true }
        return false
    }

    private var hasSharingSuccess: Bool {
        persistedLastShareStatus == shareAttemptSucceededStatus
    }

    private var sharingSuccessSection: some View {
        Section("Household Sharing") {
            Label("Invite link ready. The iOS share sheet opened with your iCloud household link.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        }
    }

    private var sharingIssueSection: some View {
        Section("Sharing Issue") {
            Text(sharingIssueDisplayMessage)
                .foregroundStyle(.red)
                .font(.footnote)

            if let technicalDetails = sharingIssueTechnicalDetails {
                DisclosureGroup("Show Technical Details", isExpanded: $showShareTechnicalDetails) {
                    Text(technicalDetails)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = technicalDetails
                    } label: {
                        Label("Copy Technical Details", systemImage: "doc.on.doc")
                    }
                }
                .font(.footnote)
            }

            if !persistedLastShareStatus.isEmpty {
                Text("Last status: \(persistedLastShareStatus)")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
    }

    private var sharingIssueDisplayMessage: String {
        if let shareErrorText, !shareErrorText.isEmpty {
            return shareErrorText
        }
        if !persistedLastShareError.isEmpty {
            return CloudSharing.friendlySharingErrorMessage(forTechnicalDetails: persistedLastShareError)
        }
        return "iCloud sharing could not finish. Please try again."
    }

    private var sharingIssueTechnicalDetails: String? {
        let rawDetails = lastCloudKitError ?? (persistedLastShareError.isEmpty ? nil : persistedLastShareError)
        guard let rawDetails, !rawDetails.isEmpty, rawDetails != sharingIssueDisplayMessage else {
            return nil
        }
        return rawDetails
    }

#if DEBUG
    private var developerDiagnosticsSection: some View {
        Section("DEBUG / Developer") {
            NavigationLink {
                CloudKitStoreDiagnosticsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "stethoscope")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Developer Diagnostics")
                        Text("Run DEBUG CloudKit schema initialization and local diagnostics")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
#endif

    // Settings cleanup: shown only in DEBUG builds now (see body), together with Delete All Data.
    private var advancedSection: some View {
        Section {
            NavigationLink {
                AdvancedSharingView(
                    household: household,
                    share: share,
                    accountStatus: accountStatus,
                    accountStatusMessage: accountStatusMessage,
                    lastError: lastCloudKitError ?? (persistedLastShareError.isEmpty ? nil : persistedLastShareError),
                    persistedLastShareStatus: persistedLastShareStatus,
                    persistentContainer: persistentContainer,
                    currentMember: appState.member,
                    currentMembership: appState.currentMembership,
                    onResetShare: { resetHouseholdShare() },
                    onReloadShareStatus: { reloadShareStatus() },
                    onForceResync: { forceCloudKitResync() }
                )
            } label: {
                Label("Advanced", systemImage: "gearshape.2")
            }

            Button("Delete All Data & Restart", role: .destructive) {
                showConfirmDeleteAll = true
            }
        }
    }


    private var shareActionsDisabled: Bool {
        !CloudSharing.isShareActionAvailable(for: accountStatus)
    }

    private var accountUnavailableFriendlyMessage: String {
        if let accountStatusMessage, !accountStatusMessage.isEmpty {
            return accountStatusMessage
        }
        return "iCloud is temporarily unavailable on this device. Please wait a moment and tap Reload share status."
    }

    private var shareAttemptSucceededStatus: String {
        "Invite link ready. Share sheet opened."
    }


    // MARK: - Actions

    private func commitHouseholdRename() {
        guard let household, appState.isCurrentHouseholdOwner else { return }
        let trimmed = householdNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            householdNameDraft = household.name ?? ""
            return
        }
        do {
            try appState.renameHousehold(trimmed)
            householdNameDraft = trimmed
        } catch {
            householdNameDraft = household.name ?? ""
            actionErrorText = error.localizedDescription
        }
    }

    private func performLeave() {
        isLeaving = true
        Task {
            defer { isLeaving = false }
            do {
                try await appState.leaveHousehold()
            } catch {
                actionErrorText = error.localizedDescription
            }
        }
    }

    private func setUserFacingShareError(_ message: String) {
        shareErrorText = message
        showShareTechnicalDetails = false
        lastCloudKitError = nil
        persistedLastShareError = ""
        CloudSharing.saveLastShareError(nil)
    }

    private func clearSharingIssue() {
        shareErrorText = nil
        showShareTechnicalDetails = false
        lastCloudKitError = nil
        persistedLastShareError = ""
        CloudSharing.saveLastShareError(nil)
    }

    private func handleShareAttemptSucceeded(_ readyShare: CKShare) {
        clearSharingIssue()
        share = readyShare
        persistedLastShareStatus = shareAttemptSucceededStatus
        CloudSharing.saveLastShareStatus(shareAttemptSucceededStatus)
    }

    private func handleShareAttemptFailed(_ error: Error) {
        let technicalMessage = CloudSharing.technicalDetails(for: error)
        let friendlyMessage = CloudSharing.friendlySharingErrorMessage(forTechnicalDetails: technicalMessage)
        print("❌ [CloudSharing] Share attempt failed: \(technicalMessage)")
        shareErrorText = friendlyMessage
        showShareTechnicalDetails = false
        lastCloudKitError = technicalMessage
        persistedLastShareError = technicalMessage
        persistedLastShareStatus = "Share attempt failed"
        CloudSharing.saveLastShareError(technicalMessage)
        CloudSharing.saveLastShareStatus("Share attempt failed")
    }

    private func reloadShareStatus() {
        guard let household else {
            share = nil
            return
        }

        share = (try? CloudSharing.fetchShare(
            for: household.objectID,
            persistentContainer: persistentContainer
        ))
#if DEBUG
        debugPrintHouseholdDiagnostics(household: household, context: context, reason: "reloadShareStatus")
        debugPrintShareStatus(for: household, persistentContainer: persistentContainer)
#endif
    }

    private func loadAccountStatus() {
        Task {
            let status = await CloudSharing.accountStatus(using: persistentContainer)
            await MainActor.run {
                accountStatus = status
                loadedAccountStatus = status
                if status == .couldNotDetermine {
                    accountStatusMessage = "iCloud account is temporarily unavailable. Sharing actions are disabled until iCloud responds."
                } else {
                    accountStatusMessage = nil
                }
            }
        }
    }

    private func accountStatusText(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "Available"
        case .noAccount: return "No account"
        case .restricted: return "Restricted"
        case .couldNotDetermine: return "Could not determine"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Members

    private func currentMemberships() -> [HouseholdMembership] {
        guard let appUser = appState.appUser else { return [] }
        return IdentityStore.memberships(for: appUser, context: context)
            .filter { !SharedHouseholdLeaveStore.contains($0) }
    }

    private func isAuthorized(_ member: HouseholdMember) -> Bool {
        IdentityStore.canAct(as: member, currentUserRecordName: appState.currentUserRecordName)
    }


    private func ensureDefaultMemberExists(in household: Household) {
        let isSharedHousehold = household.objectID.persistentStore == PersistenceController.shared.sharedStore

        if let selected = member,
           selected.household?.objectID == household.objectID,
           isAuthorized(selected) {
            SelectionStore.saveDeviceMember(selected, for: household)
            return
        }

        if let selected = SelectionStore.loadDeviceMember(for: household, context: context),
           isAuthorized(selected) {
            member = selected
            SelectionStore.save(household: household, member: selected)
            return
        }

        if isSharedHousehold {
            member = nil
            return
        }

        member = nil
    }


    private func forceCloudKitResync() {
        NotificationCenter.default.post(name: .didRequestCloudKitResync, object: nil)
        if let household {
#if DEBUG
            debugPrintHouseholdDiagnostics(household: household, context: context, reason: "force resync")
            debugPrintShareStatus(for: household, persistentContainer: persistentContainer)
#endif
        }
    }

    private func deleteAllDataAndRestart() {
        let coordinator = persistentContainer.persistentStoreCoordinator
        let stores = coordinator.persistentStores

        context.performAndWait {
            context.reset()

            let entityNames = persistentContainer.managedObjectModel.entities.compactMap(\.name)
            for store in stores {
                for entityName in entityNames {
                    let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                    fetch.includesPropertyValues = false
                    fetch.affectedStores = [store]
                    let delete = NSBatchDeleteRequest(fetchRequest: fetch)
                    delete.resultType = .resultTypeObjectIDs

                    do {
                        let result = try context.execute(delete) as? NSBatchDeleteResult
                        if let deletedObjectIDs = result?.result as? [NSManagedObjectID], !deletedObjectIDs.isEmpty {
                            let changes = [NSDeletedObjectsKey: deletedObjectIDs]
                            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
                        }
                    } catch {
                        print("❌ Delete All failed for \(entityName): \(error)")
                    }
                }
            }

            SelectionStore.clearAll()
            SharedHouseholdLeaveStore.clearAll()
            household = nil
            member = nil
            print("🧨 Delete All: cleared selection + deleted local stores; restarting")
            NotificationCenter.default.post(name: .didRequestAppRestart, object: nil)
        }
    }

    // MARK: - Create Household

    private func createHousehold() {
        errorText = nil

        let hhName = householdName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hhName.isEmpty else { return }

        let name = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? "Me" : name

        do {
            try appState.createInitialHousehold(householdName: hhName, memberName: displayName, avatar: MemberAvatarColor.default.rawValue)
            self.household = appState.household
            self.member = appState.member

            householdName = ""
            myName = ""
        } catch {
            context.rollback()
            self.errorText = error.localizedDescription
        }
    }

    private func resetHouseholdShare() {
        guard let household else { return }
        guard !shareActionsDisabled else {
            setUserFacingShareError(accountUnavailableFriendlyMessage)
            return
        }

        clearSharingIssue()
        persistedLastShareStatus = "Resetting share"
        CloudSharing.saveLastShareStatus("Resetting share")
        CloudSharing.saveLastShareError(nil)
        isSharing = true

        Task { @MainActor in
            defer { isSharing = false }

            do {
                guard let hh = try context.existingObject(with: household.objectID) as? Household else {
                    throw NSError(
                        domain: "SettingsView",
                        code: 1001,
                        userInfo: [NSLocalizedDescriptionKey: "Household could not be resolved before resetting sharing."]
                    )
                }
                if let existing = try CloudSharing.fetchShare(for: hh.objectID, persistentContainer: persistentContainer) {
                    try await CloudSharing.stopSharing(share: existing, persistentContainer: persistentContainer)
                    persistedLastShareStatus = "Stopped previous share"
                    CloudSharing.saveLastShareStatus("Stopped previous share")
                }

                _ = try await CloudSharing.fetchOrCreateShare(
                    for: hh,
                    in: context,
                    persistentContainer: persistentContainer
                )
                persistedLastShareStatus = "Created fresh share"
                CloudSharing.saveLastShareStatus("Created fresh share")
                reloadShareStatus()
            } catch {
                let technicalMessage = CloudSharing.technicalDetails(for: error)
                let friendlyMessage = CloudSharing.friendlySharingErrorMessage(forTechnicalDetails: technicalMessage)
                shareErrorText = "Reset failed: \(friendlyMessage)"
                lastCloudKitError = technicalMessage
                persistedLastShareError = technicalMessage
                CloudSharing.saveLastShareError(technicalMessage)
            }
        }
    }
}

// MARK: - Small observing rows

/// Observes the member directly so the row updates after EditProfileView saves -- SettingsView
/// itself only holds a binding, which doesn't re-render on the object's field changes.
private struct ProfileRowLabel: View {
    @ObservedObject var member: HouseholdMember

    var body: some View {
        HStack(spacing: 12) {
            MemberAvatarBadge(name: member.displayName ?? "", avatar: member.value(forKey: "avatar") as? String)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName ?? "Unnamed")
                Text("Name and color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Read-only household name for participants, observed so a leader's rename shows up live.
private struct HouseholdNameText: View {
    @ObservedObject var household: Household

    var body: some View {
        Text(household.name ?? "Household")
            .font(.headline)
    }
}

// MARK: - Members Roster (Phase 3b)

/// Renders the household's active-member roster, entirely from HouseholdMember's own fields
/// (MemberStatus) -- no HouseholdMembership lookups, which stopped being populated back in
/// Phase 3a and had made the old role/"View only"/"Invite pending" labels here silently wrong
/// since then. `@FetchRequest` stays reactive to CloudKit merges the same way it always was.
private struct MembersRosterSection: View {
    @EnvironmentObject private var appState: AppState

    let household: Household

    @FetchRequest private var members: FetchedResults<HouseholdMember>

    @State private var pendingRemoveAccess: HouseholdMember?
    @State private var isRemovingAccess = false
    @State private var errorText: String?

    init(household: Household) {
        self.household = household

        // Current-roster context: a departed member (isActive == NO) is intentionally excluded
        // here — they still show up wherever their historical ratings/entries are attributed,
        // just not in the active membership list this screen manages.
        _members = FetchRequest<HouseholdMember>(
            sortDescriptors: [
                NSSortDescriptor(
                    key: "displayName",
                    ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
            ],
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                householdScopedPredicate(household, idKey: "householdId"),
                NSPredicate(format: "isActive == YES")
            ]),
            animation: .default
        )
    }

    private var isCurrentUserLeader: Bool {
        (appState.member?.value(forKey: "role") as? String) == "leader"
    }

    var body: some View {
        Group {
            if members.isEmpty {
                ContentUnavailableView("No members yet", systemImage: "person.3")
            } else {
                ForEach(Array(members)) { managedMember in
                    memberRow(managedMember)
                }
            }
        }
        .confirmationDialog(
            pendingRemoveAccess.map { "Remove \($0.displayName ?? "this member")’s Access?" } ?? "Remove Access?",
            isPresented: Binding(get: { pendingRemoveAccess != nil }, set: { if !$0 { pendingRemoveAccess = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingRemoveAccess {
                Button("Remove Access", role: .destructive) {
                    performRemoveAccess(pendingRemoveAccess)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes their iCloud access to this household. Their profile and past ratings stay in the household.")
        }
        .alert("Couldn’t Complete", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder
    private func memberRow(_ managedMember: HouseholdMember) -> some View {
        let status = MemberStatus.resolve(for: managedMember, currentUserRecordName: appState.currentUserRecordName)
        let canEditPhoneToggle = isCurrentUserLeader || managedMember.objectID == appState.member?.objectID

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: status.isLeader ? "crown.fill" : "person.circle.fill")
                    .font(.title3)
                    .foregroundStyle(status.isLeader ? .yellow : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(managedMember.displayName ?? "Unnamed")
                        .font(.body)
                    Text(status.isLeader ? "\(status.label) · Leader" : status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if MemberStatus.isInviteEligible(managedMember) {
                    InviteMemberButton(member: managedMember, household: household, isResend: status.kind == .invited)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(isRemovingAccess)
                }
            }

            if canEditPhoneToggle {
                Toggle("Has own iPhone", isOn: hasOwnIPhoneBinding(for: managedMember))
                    .font(.caption)
                    .disabled(isRemovingAccess)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isCurrentUserLeader, status.kind == .joined {
                Button("Remove Access", role: .destructive) {
                    pendingRemoveAccess = managedMember
                }
                .disabled(isRemovingAccess)
            }
        }
    }

    private func hasOwnIPhoneBinding(for managedMember: HouseholdMember) -> Binding<Bool> {
        Binding(
            get: { (managedMember.value(forKey: "hasOwnIPhone") as? Bool) ?? false },
            set: { newValue in
                do {
                    try appState.setHasOwnIPhone(newValue, for: managedMember)
                } catch {
                    errorText = error.localizedDescription
                }
            }
        )
    }

    private func performRemoveAccess(_ managedMember: HouseholdMember) {
        pendingRemoveAccess = nil
        isRemovingAccess = true
        Task {
            defer { isRemovingAccess = false }
            do {
                try await appState.removeAccess(for: managedMember, household: household)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - Advanced Screen

private struct AdvancedSharingView: View {
    let household: Household?
    let share: CKShare?
    let accountStatus: CKAccountStatus
    let accountStatusMessage: String?
    let lastError: String?
    let persistedLastShareStatus: String
    let persistentContainer: NSPersistentContainer
    let currentMember: HouseholdMember?
    let currentMembership: HouseholdMembership?

    let onResetShare: () -> Void
    let onReloadShareStatus: () -> Void
    let onForceResync: () -> Void

    var body: some View {
        Form {
            Section("Share Status") {
                HStack {
                    Text("iCloud account")
                    Spacer()
                    Text(accountStatusLabel)
                        .foregroundStyle(.secondary)
                }

                if let accountStatusMessage, !accountStatusMessage.isEmpty {
                    Text(accountStatusMessage)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }

                if let share {
                    HStack {
                        Text("Share created")
                        Spacer()
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }

                    let title = (share[CKShare.SystemFieldKey.title] as? String) ?? ""
                    if !title.isEmpty {
                        HStack {
                            Text("Share title")
                            Spacer()
                            Text(title)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    HStack {
                        Text("Share created")
                        Spacer()
                        Text("Share missing")
                            .foregroundStyle(.secondary)
                    }
                }

                if !persistedLastShareStatus.isEmpty {
                    Text("Last status: \(persistedLastShareStatus)")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }

                Button("Reload share status") { onReloadShareStatus() }
            }

#if DEBUG
            Section("Troubleshooting") {
                if let lastError, !lastError.isEmpty {
                    Text(lastError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                } else {
                    Text("No recent errors.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }

                if household != nil {
                    Button("Reset Household Share", role: .destructive) {
                        onResetShare()
                    }
                    .disabled(!CloudSharing.isShareActionAvailable(for: accountStatus))

                    Button("Force CloudKit Resync") {
                        onForceResync()
                    }
                }

                NavigationLink("Share Diagnostics") {
                    ShareDiagnosticsView(
                        household: household,
                        accountStatus: accountStatus,
                        accountStatusMessage: accountStatusMessage,
                        lastError: lastError,
                        persistentContainer: persistentContainer,
                        currentMember: currentMember,
                        currentMembership: currentMembership
                    )
                }
            }
#endif
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var accountStatusLabel: String {
        switch accountStatus {
        case .available: return "Available"
        case .noAccount: return "No account"
        case .restricted: return "Restricted"
        case .couldNotDetermine: return "Could not determine"
        @unknown default: return "Unknown"
        }
    }
}

private struct ShareDiagnosticsView: View {
    let household: Household?
    let accountStatus: CKAccountStatus
    let accountStatusMessage: String?
    let lastError: String?
    let persistentContainer: NSPersistentContainer
    let currentMember: HouseholdMember?
    let currentMembership: HouseholdMembership?

    @Environment(\.managedObjectContext) private var context
    @State private var diagnostics = ShareDiagnosticsSnapshot.empty

    var body: some View {
        Form {
            Section("CloudKit / Stores") {
                diagnosticRow("Container", diagnostics.containerIdentifier)
                diagnosticRow("Private store", diagnostics.privateStoreLabel)
                diagnosticRow("Shared store", diagnostics.sharedStoreLabel)
                diagnosticRow("Private loaded", diagnostics.privateStoreLoaded ? "Yes" : "No")
                diagnosticRow("Shared loaded", diagnostics.sharedStoreLoaded ? "Yes" : "No")
                diagnosticRow("Persistent history", diagnostics.persistentHistoryEnabledText)
                diagnosticRow("Remote change notifications", diagnostics.remoteChangeNotificationsEnabledText)
                diagnosticRow("iCloud account", accountStatusLabel)

                if let accountStatusMessage, !accountStatusMessage.isEmpty {
                    Text(accountStatusMessage)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }

            Section("Current Active Household") {
                HouseholdDiagnosticSummaryView(summary: diagnostics.activeHousehold)

                diagnosticRow("Currently selected", diagnostics.activeHousehold.isSelected ? "Yes" : "No")
                diagnosticRow("Selected member", diagnostics.selectedMemberText)
                diagnosticRow("Current membership", diagnostics.currentMembershipText)
            }

            Section("Active Household Share") {
                ShareDiagnosticStatusView(status: diagnostics.activeShareStatus)
            }

            Section("Local Shared-Store Households") {
                if diagnostics.sharedHouseholds.isEmpty {
                    ContentUnavailableView("No local shared households", systemImage: "person.3.sequence")
                } else {
                    ForEach(diagnostics.sharedHouseholds) { sharedHousehold in
                        SharedHouseholdDiagnosticRow(summary: sharedHousehold)
                    }
                }
            }

            Section("Local Stale References") {
                diagnosticRow("Selected household URI", diagnostics.selection.selectedHouseholdURI ?? "None")
                diagnosticRow("Selected household resolves", diagnostics.selection.selectedHouseholdResolves ? "Yes" : "No")
                if let resolvedURI = diagnostics.selection.selectedHouseholdObjectURI {
                    diagnosticRow("Resolved household object", resolvedURI)
                }

                diagnosticRow("Selected member URI", diagnostics.selection.selectedMemberURI ?? "None")
                diagnosticRow("Selected member resolves", diagnostics.selection.selectedMemberResolves ? "Yes" : "No")
                if let resolvedURI = diagnostics.selection.selectedMemberObjectURI {
                    diagnosticRow("Resolved member object", resolvedURI)
                }

                diagnosticRow("Pending invite URL", diagnostics.pendingInviteURL ?? "None")
                diagnosticRow("Last share error", lastError ?? "None")
            }

            Section("Last Observed Zone Error") {
                diagnosticRow("Zone name", diagnostics.lastObservedZoneName)
                diagnosticRow("Mentioned in saved error", diagnostics.lastErrorMentionsObservedZone ? "Yes" : "No")
                Text("This screen is read-only. If this zone does not match the active or listed shared households, it may exist only in Core Data + CloudKit mirroring metadata for a previously deleted or revoked share.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Share Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshDiagnostics() }
    }

    private func refreshDiagnostics() {
        diagnostics = ShareDiagnosticsSnapshot.build(
            household: household,
            currentMember: currentMember,
            currentMembership: currentMembership,
            lastError: lastError,
            persistentContainer: persistentContainer,
            context: context
        )
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var accountStatusLabel: String {
        switch accountStatus {
        case .available: return "Available"
        case .noAccount: return "No account"
        case .restricted: return "Restricted"
        case .couldNotDetermine: return "Could not determine"
        @unknown default: return "Unknown"
        }
    }
}

private struct HouseholdDiagnosticSummaryView: View {
    let summary: HouseholdDiagnosticSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            diagnosticRow("Name", summary.name)
            diagnosticRow("UUID", summary.uuid)
            diagnosticRow("Object URI", summary.objectURI)
            diagnosticRow("Store scope", summary.storeScope)
            diagnosticRow("Created", summary.createdText)
        }
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

private struct SharedHouseholdDiagnosticRow: View {
    let summary: SharedHouseholdDiagnosticSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HouseholdDiagnosticSummaryView(summary: summary.household)

            HStack {
                Label(summary.matchesActiveHousehold ? "Matches active" : "Not active", systemImage: summary.matchesActiveHousehold ? "checkmark.circle" : "circle")
                Spacer()
                Label(summary.isHiddenOrLeft ? "Hidden/left" : "Visible", systemImage: summary.isHiddenOrLeft ? "eye.slash" : "eye")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Memberships")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(summary.membershipText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            ShareDiagnosticStatusView(status: summary.shareStatus)
        }
        .padding(.vertical, 6)
    }
}

private struct ShareDiagnosticStatusView: View {
    let status: ShareDiagnosticStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            diagnosticRow("fetchShares(matching:)", status.fetchStatusText)
            diagnosticRow("CKShare record", status.recordName ?? "None")
            diagnosticRow("CKShare zone", status.zoneName ?? "None")
            diagnosticRow("CKShare zone owner", status.zoneOwnerName ?? "None")
            diagnosticRow("Matches observed ZoneDeleted zone", status.matchesObservedZone ? "Yes" : "No")
            diagnosticRow("Participants", status.participantsText)
            if let errorText = status.errorText {
                diagnosticRow("Error", errorText)
            }
        }
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

private struct ShareDiagnosticsSnapshot {
    static let observedZoneName = "com.apple.coredata.cloudkit.share.931A2312-7985-4B36-A891-0A16DCC9AB09"

    let containerIdentifier: String
    let privateStoreLabel: String
    let sharedStoreLabel: String
    let privateStoreLoaded: Bool
    let sharedStoreLoaded: Bool
    let persistentHistoryEnabledText: String
    let remoteChangeNotificationsEnabledText: String
    let activeHousehold: HouseholdDiagnosticSummary
    let activeShareStatus: ShareDiagnosticStatus
    let sharedHouseholds: [SharedHouseholdDiagnosticSummary]
    let selectedMemberText: String
    let currentMembershipText: String
    let selection: SelectionStore.DiagnosticSnapshot
    let pendingInviteURL: String?
    let lastObservedZoneName: String
    let lastErrorMentionsObservedZone: Bool

    static var empty: ShareDiagnosticsSnapshot {
        ShareDiagnosticsSnapshot(
            containerIdentifier: "Unknown",
            privateStoreLabel: "Not loaded",
            sharedStoreLabel: "Not loaded",
            privateStoreLoaded: false,
            sharedStoreLoaded: false,
            persistentHistoryEnabledText: "Unknown",
            remoteChangeNotificationsEnabledText: "Unknown",
            activeHousehold: .none,
            activeShareStatus: .notChecked(reason: "No active household"),
            sharedHouseholds: [],
            selectedMemberText: "None",
            currentMembershipText: "None",
            selection: SelectionStore.DiagnosticSnapshot(
                selectedHouseholdURI: nil,
                selectedMemberURI: nil,
                selectedHouseholdResolves: false,
                selectedMemberResolves: false,
                selectedHouseholdObjectURI: nil,
                selectedMemberObjectURI: nil
            ),
            pendingInviteURL: nil,
            lastObservedZoneName: observedZoneName,
            lastErrorMentionsObservedZone: false
        )
    }

    static func build(
        household: Household?,
        currentMember: HouseholdMember?,
        currentMembership: HouseholdMembership?,
        lastError: String?,
        persistentContainer: NSPersistentContainer,
        context: NSManagedObjectContext
    ) -> ShareDiagnosticsSnapshot {
        let persistence = PersistenceController.shared
        let selection = SelectionStore.diagnosticSnapshot(context: context)
        let sharedHouseholds = fetchSharedHouseholdSummaries(
            activeHousehold: household,
            persistentContainer: persistentContainer,
            context: context
        )

        return ShareDiagnosticsSnapshot(
            containerIdentifier: CloudSharing.containerIdentifier(from: persistentContainer),
            privateStoreLabel: storeLabel(for: persistence.privateStore),
            sharedStoreLabel: storeLabel(for: persistence.sharedStore),
            privateStoreLoaded: persistence.privateStore != nil,
            sharedStoreLoaded: persistence.sharedStore != nil,
            persistentHistoryEnabledText: optionStatus(for: NSPersistentHistoryTrackingKey, in: persistentContainer),
            remoteChangeNotificationsEnabledText: optionStatus(for: NSPersistentStoreRemoteChangeNotificationPostOptionKey, in: persistentContainer),
            activeHousehold: HouseholdDiagnosticSummary(household: household, selection: selection),
            activeShareStatus: shareStatus(for: household, persistentContainer: persistentContainer),
            sharedHouseholds: sharedHouseholds,
            selectedMemberText: memberText(currentMember),
            currentMembershipText: membershipText(currentMembership),
            selection: selection,
            pendingInviteURL: PendingInviteStore.load()?.absoluteString,
            lastObservedZoneName: observedZoneName,
            lastErrorMentionsObservedZone: (lastError ?? "").contains(observedZoneName)
        )
    }

    private static func fetchSharedHouseholdSummaries(
        activeHousehold: Household?,
        persistentContainer: NSPersistentContainer,
        context: NSManagedObjectContext
    ) -> [SharedHouseholdDiagnosticSummary] {
        guard let sharedStore = PersistenceController.shared.sharedStore else { return [] }
        let request = Household.fetchRequest()
        request.affectedStores = [sharedStore]
        request.includesPendingChanges = true
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        let households = (try? context.fetch(request) as? [Household]) ?? []
        return households.map { household in
            SharedHouseholdDiagnosticSummary(
                household: HouseholdDiagnosticSummary(household: household, selection: SelectionStore.diagnosticSnapshot(context: context)),
                membershipText: membershipSummary(for: household, context: context),
                isHiddenOrLeft: SharedHouseholdLeaveStore.contains(household),
                matchesActiveHousehold: household.objectID == activeHousehold?.objectID,
                shareStatus: shareStatus(for: household, persistentContainer: persistentContainer)
            )
        }
    }

    // Phase 1 (CKSyncEngine migration): disabled, not deleted. `persistentContainer` is now a
    // plain NSPersistentContainer, which has no `fetchShares(matching:)` -- that was
    // NSPersistentCloudKitContainer-mirroring-specific, and there is never a resolvable share
    // while sharing is disabled anyway.
    private static func shareStatus(for household: Household?, persistentContainer: NSPersistentContainer) -> ShareDiagnosticStatus {
        guard household != nil else { return .notChecked(reason: "No household") }
        return .notChecked(reason: "Sharing disabled in Phase 1 (CKSyncEngine migration)")
    }

    private static func membershipSummary(for household: Household, context: NSManagedObjectContext) -> String {
        let request = NSFetchRequest<HouseholdMembership>(entityName: "HouseholdMembership")
        request.predicate = NSPredicate(format: "household == %@", household)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

        let memberships = (try? context.fetch(request)) ?? []
        guard !memberships.isEmpty else { return "0 memberships" }

        let statusCounts = Dictionary(grouping: memberships, by: { ($0.status ?? "<nil>").isEmpty ? "<empty>" : ($0.status ?? "<nil>") })
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        return "\(memberships.count) memberships (\(statusCounts))"
    }

    private static func optionStatus(for key: String, in persistentContainer: NSPersistentContainer) -> String {
        let values = persistentContainer.persistentStoreDescriptions.map { description -> String in
            let scope = scopeLabel(for: description.cloudKitContainerOptions?.databaseScope)
            let value = description.options[key]
            return "\(scope): \(boolText(value))"
        }
        return values.isEmpty ? "Unknown" : values.joined(separator: ", ")
    }

    private static func boolText(_ value: Any?) -> String {
        if let number = value as? NSNumber { return number.boolValue ? "enabled" : "disabled" }
        if let bool = value as? Bool { return bool ? "enabled" : "disabled" }
        return "unknown"
    }

    private static func storeLabel(for store: NSPersistentStore?) -> String {
        guard let store else { return "Not loaded" }
        guard let url = store.url else { return "<no URL>" }
        return "\(url.lastPathComponent) — \(url.absoluteString)"
    }

    private static func scopeLabel(for scope: CKDatabase.Scope?) -> String {
        switch scope {
        case .private: return "private"
        case .shared: return "shared"
        case .public: return "public"
        default: return "unknown"
        }
    }

    private static func memberText(_ member: HouseholdMember?) -> String {
        guard let member else { return "None" }
        let name = member.displayName ?? "Unnamed member"
        return "\(name) — \(member.objectID.uriRepresentation().absoluteString)"
    }

    private static func membershipText(_ membership: HouseholdMembership?) -> String {
        guard let membership else { return "None" }
        let status = membership.status ?? "<nil>"
        let role = membership.role ?? "<nil>"
        return "status=\(status) role=\(role) uri=\(membership.objectID.uriRepresentation().absoluteString)"
    }
}

private struct HouseholdDiagnosticSummary {
    let name: String
    let uuid: String
    let objectURI: String
    let storeScope: String
    let createdText: String
    let isSelected: Bool

    static let none = HouseholdDiagnosticSummary(
        name: "None",
        uuid: "None",
        objectURI: "None",
        storeScope: "None",
        createdText: "None",
        isSelected: false
    )

    private init(
        name: String,
        uuid: String,
        objectURI: String,
        storeScope: String,
        createdText: String,
        isSelected: Bool
    ) {
        self.name = name
        self.uuid = uuid
        self.objectURI = objectURI
        self.storeScope = storeScope
        self.createdText = createdText
        self.isSelected = isSelected
    }

    init(household: Household?, selection: SelectionStore.DiagnosticSnapshot) {
        guard let household else {
            self = .none
            return
        }

        name = household.name ?? "Unnamed household"
        uuid = household.id?.uuidString ?? "<nil>"
        objectURI = household.objectID.uriRepresentation().absoluteString
        storeScope = Self.scope(for: household.objectID.persistentStore)
        if let createdAt = household.createdAt {
            createdText = createdAt.formatted(date: .abbreviated, time: .shortened)
        } else {
            createdText = "<nil>"
        }
        isSelected = selection.selectedHouseholdObjectURI == objectURI
    }

    private static func scope(for store: NSPersistentStore?) -> String {
        guard let store else { return "unknown" }
        if store == PersistenceController.shared.privateStore { return "private" }
        if store == PersistenceController.shared.sharedStore { return "shared" }
        let filename = store.url?.lastPathComponent ?? "unknown"
        if filename.localizedCaseInsensitiveContains("shared") { return "shared (filename inferred)" }
        return "private/unknown (filename: \(filename))"
    }
}

private struct SharedHouseholdDiagnosticSummary: Identifiable {
    var id: String { household.objectURI }
    let household: HouseholdDiagnosticSummary
    let membershipText: String
    let isHiddenOrLeft: Bool
    let matchesActiveHousehold: Bool
    let shareStatus: ShareDiagnosticStatus
}

private struct ShareDiagnosticStatus {
    let fetchSucceeded: Bool
    let recordName: String?
    let zoneName: String?
    let zoneOwnerName: String?
    let participants: [ShareParticipantDiagnostic]
    let errorText: String?

    var fetchStatusText: String {
        if let errorText, !errorText.isEmpty { return "Error" }
        return fetchSucceeded ? "Succeeded" : "Not checked"
    }

    var participantsText: String {
        if participants.isEmpty { return "None / unavailable" }
        return participants.map(\.summary).joined(separator: "\n")
    }

    var matchesObservedZone: Bool {
        zoneName == ShareDiagnosticsSnapshot.observedZoneName
    }

    static func notChecked(reason: String) -> ShareDiagnosticStatus {
        ShareDiagnosticStatus(fetchSucceeded: false, recordName: nil, zoneName: nil, zoneOwnerName: nil, participants: [], errorText: reason)
    }
}

private struct ShareParticipantDiagnostic {
    let summary: String

    init(participant: CKShare.Participant) {
        let name = participant.userIdentity.nameComponents?.formatted() ?? "Unknown participant"
        summary = "\(name) permission=\(Self.permissionText(participant.permission)) role=\(Self.roleText(participant.role)) acceptance=\(Self.acceptanceText(participant.acceptanceStatus))"
    }

    private static func permissionText(_ permission: CKShare.ParticipantPermission) -> String {
        switch permission {
        case .unknown: return "unknown"
        case .none: return "none"
        case .readOnly: return "readOnly"
        case .readWrite: return "readWrite"
        @unknown default: return "unknown-default"
        }
    }

    private static func roleText(_ role: CKShare.ParticipantRole) -> String {
        switch role {
        case .unknown: return "unknown"
        case .owner: return "owner"
        case .privateUser: return "privateUser"
        case .publicUser: return "publicUser"
        @unknown default: return "unknown-default"
        }
    }

    private static func acceptanceText(_ status: CKShare.ParticipantAcceptanceStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .removed: return "removed"
        @unknown default: return "unknown-default"
        }
    }
}
