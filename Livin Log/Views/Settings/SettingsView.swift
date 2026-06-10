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

    // Presents Apple's official CloudKit sharing UI.
    @State private var showingInviteShareSheet = false

    // Bulletproof join flow (paste link)
    @State private var showingPasteInviteSheet = false
    @State private var pendingInvite: PendingShareInvite?
    @State private var sharedHouseholdNeedingProfile: Household?

    @AppStorage(CloudSharing.lastShareErrorDefaultsKey) private var persistedLastShareError = ""
    @AppStorage(CloudSharing.lastShareStatusDefaultsKey) private var persistedLastShareStatus = ""

    private let persistentContainer = PersistenceController.shared.container

    var body: some View {
        Form {
            householdSection
            joinHouseholdSection
            notificationsSection
            membersSection
            profilesSection

            if hasSharingIssue {
                sharingIssueSection
            } else if hasSharingSuccess {
                sharingSuccessSection
            }

#if DEBUG
            developerDiagnosticsSection
#endif

            advancedSection

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
        }
        .onChange(of: household?.objectID) { _, _ in
            if let hh = household { ensureDefaultMemberExists(in: hh) }
            reloadShareStatus()
        }

        // Invite sheet (owner sharing)
        .sheet(isPresented: $showingInviteShareSheet, onDismiss: {
            isSharing = false
            reloadShareStatus()
        }) {
            if let household {
                CloudKitHouseholdSharingSheet(
                    household: household,
                    onDone: { showingInviteShareSheet = false },
                    onShareReady: { readyShare in
                        handleShareAttemptSucceeded(readyShare)
                    },
                    onError: { error in
                        handleShareAttemptFailed(error)
                        showingInviteShareSheet = false
                        isSharing = false
                    }
                )
                .ignoresSafeArea()
            }
        }

        // Paste link sheet (bulletproof join)
        .sheet(isPresented: $showingPasteInviteSheet) {
            PasteInviteLinkSheet(
                isSignedIn: appState.appUser != nil,
                onInviteReady: { invite in
                    Task { @MainActor in
                        pendingInvite = invite
                    }
                },
                onInviteDeferred: { _ in
                    setUserFacingShareError("Sign in with Apple to finish joining this household invite.")
                }
            )
        }

        // Accept invite sheet
        .sheet(item: $pendingInvite) { invite in
            AcceptHouseholdInviteSheet(
                pendingInvite: invite,
                onAccepted: {
                    NotificationCenter.default.post(name: .didAcceptCloudKitShare, object: nil)
                    await MainActor.run {
                        reloadShareStatus()
                        resolveSharedMemberPromptNeed()
                    }
                },
                onCancelInvite: {
                    PendingInviteStore.clear(reason: "cancelled from settings accept sheet")
                    pendingInvite = nil
                },
                isSignedIn: appState.appUser != nil
            )
        }
        .sheet(item: $sharedHouseholdNeedingProfile) { sharedHousehold in
            CreateMemberProfileSheet(household: sharedHousehold) { createdMember in
                household = sharedHousehold
                member = createdMember
                SelectionStore.save(household: sharedHousehold, member: createdMember)
                SelectionStore.saveDeviceMember(createdMember, for: sharedHousehold)
            }
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

                Button {
                    inviteMember()
                } label: {
                    HStack {
                        Text(isSharing ? "Preparing invite…" : "Invite Someone")
                        Spacer()
                        if isSharing {
                            ProgressView()
                        } else {
                            Image(systemName: "person.badge.plus")
                        }
                    }
                }
                 .disabled(isSharing || shareActionsDisabled || appState.appUser == nil || !appState.isCurrentMemberAuthorized())
                if appState.appUser == nil {
                    Text("Sign in with Apple before sharing this household.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } else if !appState.isCurrentMemberAuthorized() {
                    Text("Select or create your claimed member profile before sharing this household.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                if shareActionsDisabled {
                    Text(accountUnavailableFriendlyMessage)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            } else {
                Text("Create a household to begin.")
                    .foregroundStyle(.secondary)

                TextField("Household name", text: $householdName)
                TextField("Your name (optional)", text: $myName)

                Button("Create Household") {
                    createHousehold()
                }
                .disabled(householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.appUser == nil)
            }
        }
    }

    private var joinHouseholdSection: some View {
        Section("Join Household") {
            Button {
                showingPasteInviteSheet = true
            } label: {
                Label("Join with Invite Link", systemImage: "link")
            }
            if appState.appUser == nil {
                Text("Sign in with Apple before joining so your invite membership can be tied to your durable identity.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
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

    private var membersSection: some View {
        Section("Members") {
            if let household {
                let members = fetchMembers(for: household)
                if members.isEmpty {
                    ContentUnavailableView("No members yet", systemImage: "person.3")
                } else {
                    ForEach(members) { m in
                        HStack(spacing: 12) {
                            Image(systemName: "person.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.displayName ?? "Unnamed")
                                    .font(.body)

                                if m == member {
                                    Text("You")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
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
                    onCleanupCompleted: { await appState.start(callSite: "SettingsView.profileCleanup") }
                )
            } label: {
                Label("Manage Duplicate Profiles", systemImage: "person.2.badge.gearshape")
            }
            Text("Review duplicate-looking profiles with household names, creation dates, roles, and safe swipe-to-delete actions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

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


    private func resolveSharedMemberPromptNeed() {
        let (selectedHousehold, selectedMember) = SelectionStore.load(context: context)
        guard let selectedHousehold else {
            sharedHouseholdNeedingProfile = nil
            return
        }

        household = selectedHousehold

        let isShared = selectedHousehold.objectID.persistentStore == PersistenceController.shared.sharedStore
        let selectedMatches = selectedMember?.household?.objectID == selectedHousehold.objectID

        if selectedMatches, let selectedMember, isAuthorized(selectedMember) {
            member = selectedMember
            print("✅ Using authorized selected member for this household")
            SelectionStore.saveDeviceMember(selectedMember, for: selectedHousehold)
            sharedHouseholdNeedingProfile = nil
            return
        }

        if let deviceMember = SelectionStore.loadDeviceMember(for: selectedHousehold, context: context),
           isAuthorized(deviceMember) {
            member = deviceMember
            SelectionStore.save(household: selectedHousehold, member: deviceMember)
            print("✅ Using authorized cached member for this household")
            sharedHouseholdNeedingProfile = nil
            return
        }

        member = nil

        if isShared {
            print("ℹ️ Selected household is shared; no local member found; prompting for name")
            sharedHouseholdNeedingProfile = selectedHousehold
        } else {
            sharedHouseholdNeedingProfile = nil
        }
    }

    // MARK: - Actions

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

    private func inviteMember() {
        guard household != nil else { return }
        guard appState.appUser != nil, appState.isCurrentMemberAuthorized() else {
            setUserFacingShareError("Select or create your claimed member profile before sharing this household.")
            return
        }
        guard !shareActionsDisabled else {
            setUserFacingShareError(accountUnavailableFriendlyMessage)
            return
        }

        clearSharingIssue()
        persistedLastShareStatus = "Preparing invite link…"
        CloudSharing.saveLastShareStatus("Preparing invite link…")
        CloudSharing.saveLastShareError(nil)

        isSharing = true
        showingInviteShareSheet = true
        print("ℹ️ [CloudSharing] Share attempt started for household invite")
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

    private func fetchMembers(for household: Household) -> [HouseholdMember] {
        let req: NSFetchRequest<HouseholdMember> = HouseholdMember.fetchRequest()
        req.predicate = NSPredicate(format: "household == %@", household)
        req.sortDescriptors = [
            NSSortDescriptor(
                key: "displayName",
                ascending: true,
                selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
            )
        ]

        do {
            return try context.fetch(req)
        } catch {
            print("Fetch members failed:", error)
            return []
        }
    }

    private func currentMemberships() -> [HouseholdMembership] {
        guard let appUser = appState.appUser else { return [] }
        return IdentityStore.memberships(for: appUser, context: context)
            .filter { !SharedHouseholdLeaveStore.contains($0) }
    }

    private func isAuthorized(_ member: HouseholdMember) -> Bool {
        IdentityStore.canAct(as: member, appUser: appState.appUser, context: context)
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
            try appState.createInitialHousehold(name: hhName, memberName: displayName)
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

// MARK: - Advanced Screen

private struct AdvancedSharingView: View {
    let household: Household?
    let share: CKShare?
    let accountStatus: CKAccountStatus
    let accountStatusMessage: String?
    let lastError: String?
    let persistedLastShareStatus: String
    let persistentContainer: NSPersistentCloudKitContainer
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

            Section("How sharing works") {
                Text("Inviting someone creates an iCloud share link for your household. They can tap the link or manually enter the code/token from the link, then create their own claimed member profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

#if DEBUG
                if household != nil {
                    Button("Reset Household Share", role: .destructive) {
                        onResetShare()
                    }
                    .disabled(!CloudSharing.isShareActionAvailable(for: accountStatus))

                    Button("Force CloudKit Resync") {
                        onForceResync()
                    }
                }
#endif

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
    let persistentContainer: NSPersistentCloudKitContainer
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
        persistentContainer: NSPersistentCloudKitContainer,
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
        persistentContainer: NSPersistentCloudKitContainer,
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

    private static func shareStatus(for household: Household?, persistentContainer: NSPersistentCloudKitContainer) -> ShareDiagnosticStatus {
        guard let household else { return .notChecked(reason: "No household") }
        do {
            let shares = try persistentContainer.fetchShares(matching: [household.objectID])
            guard let share = shares[household.objectID] else {
                return ShareDiagnosticStatus(fetchSucceeded: true, recordName: nil, zoneName: nil, zoneOwnerName: nil, participants: [], errorText: nil)
            }
            return ShareDiagnosticStatus(
                fetchSucceeded: true,
                recordName: share.recordID.recordName,
                zoneName: share.recordID.zoneID.zoneName,
                zoneOwnerName: share.recordID.zoneID.ownerName,
                participants: share.participants.map(ShareParticipantDiagnostic.init(participant:)),
                errorText: nil
            )
        } catch {
            let nsError = error as NSError
            return ShareDiagnosticStatus(
                fetchSucceeded: false,
                recordName: nil,
                zoneName: nil,
                zoneOwnerName: nil,
                participants: [],
                errorText: "domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)"
            )
        }
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

    private static func optionStatus(for key: String, in persistentContainer: NSPersistentCloudKitContainer) -> String {
        let values = persistentContainer.persistentStoreDescriptions.map { description -> String in
            let scope = scopeLabel(for: description.cloudKitContainerOptions?.databaseScope)
            let value = description.options[AnyHashable(key)]
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
