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

            if hasSharingIssue {
                sharingIssueSection
            }

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
                    onError: { error in
                        let message = error.localizedDescription
                        shareErrorText = message
                        lastCloudKitError = message
                        persistedLastShareError = message
                        CloudSharing.saveLastShareError(message)
                        showingInviteShareSheet = false
                        isSharing = false
                    }
                )
                .ignoresSafeArea()
            }
        }

        // Paste link sheet (bulletproof join)
        .sheet(isPresented: $showingPasteInviteSheet) {
            PasteInviteLinkSheet { invite in
                Task { @MainActor in
                    pendingInvite = invite
                }
            }
        }

        // Accept invite sheet
        .sheet(item: $pendingInvite) { invite in
            AcceptHouseholdInviteSheet(pendingInvite: invite) {
                NotificationCenter.default.post(name: .didAcceptCloudKitShare, object: nil)
                await MainActor.run {
                    reloadShareStatus()
                    resolveSharedMemberPromptNeed()
                }
            }
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
                 .disabled(isSharing || shareActionsDisabled)
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

    private var hasSharingIssue: Bool {
        if let shareErrorText, !shareErrorText.isEmpty { return true }
        if !persistedLastShareError.isEmpty { return true }
        return false
    }

    private var sharingIssueSection: some View {
        Section("Sharing Issue") {
            Text(shareErrorText ?? persistedLastShareError)
                .foregroundStyle(.red)
                .font(.footnote)

            if !persistedLastShareStatus.isEmpty {
                Text("Last status: \(persistedLastShareStatus)")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
    }

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


    private func resolveSharedMemberPromptNeed() {
        let (selectedHousehold, selectedMember) = SelectionStore.load(context: context)
        guard let selectedHousehold else {
            sharedHouseholdNeedingProfile = nil
            return
        }

        household = selectedHousehold

        let isShared = selectedHousehold.objectID.persistentStore == PersistenceController.shared.sharedStore
        let selectedMatches = selectedMember?.household?.objectID == selectedHousehold.objectID

        if selectedMatches, let selectedMember {
            member = selectedMember
            print("✅ Using existing selected member for this household")
            SelectionStore.saveDeviceMember(selectedMember, for: selectedHousehold)
            sharedHouseholdNeedingProfile = nil
            return
        }

        if let deviceMember = SelectionStore.loadDeviceMember(for: selectedHousehold, context: context) {
            member = deviceMember
            SelectionStore.save(household: selectedHousehold, member: deviceMember)
            print("✅ Using existing selected member for this household")
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

    private func inviteMember() {
        guard household != nil else { return }
        guard !shareActionsDisabled else {
            shareErrorText = accountUnavailableFriendlyMessage
            return
        }

        shareErrorText = nil
        lastCloudKitError = nil
        persistedLastShareError = ""
        persistedLastShareStatus = "Preparing invite link…"
        CloudSharing.saveLastShareStatus("Preparing invite link…")
        CloudSharing.saveLastShareError(nil)

        isSharing = true
        showingInviteShareSheet = true
        print("ℹ️ Presenting iOS share sheet (Messages) for household invite")
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

    private func ensureDefaultMemberExists(in household: Household) {
        let isSharedHousehold = household.objectID.persistentStore == PersistenceController.shared.sharedStore
        let members = fetchMembers(for: household)

        if let selected = member, selected.household?.objectID == household.objectID {
            SelectionStore.saveDeviceMember(selected, for: household)
            return
        }

        if let selected = SelectionStore.loadDeviceMember(for: household, context: context) {
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
            shareErrorText = accountUnavailableFriendlyMessage
            return
        }

        shareErrorText = nil
        lastCloudKitError = nil
        persistedLastShareError = ""
        persistedLastShareStatus = "Resetting share"
        CloudSharing.saveLastShareStatus("Resetting share")
        CloudSharing.saveLastShareError(nil)
        isSharing = true

        Task { @MainActor in
            defer { isSharing = false }

            do {
                let hh = try context.existingObject(with: household.objectID) as! Household
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
                let message = "Reset failed: \(error.localizedDescription)"
                shareErrorText = message
                lastCloudKitError = error.localizedDescription
                persistedLastShareError = message
                CloudSharing.saveLastShareError(message)
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
                Text("Inviting someone creates an iCloud share for your household. People you invite can see and edit the same household data.")
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
                        persistentContainer: persistentContainer
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

    @State private var shareRecordName: String?
    @State private var canFetchShare = false

    var body: some View {
        Form {
            Section("CloudKit") {
                HStack {
                    Text("Container")
                    Spacer()
                    Text(CloudSharing.containerIdentifier(from: persistentContainer))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack {
                    Text("Account status")
                    Spacer()
                    Text(accountStatusLabel)
                        .foregroundStyle(.secondary)
                }

                if let accountStatusMessage, !accountStatusMessage.isEmpty {
                    Text(accountStatusMessage)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }

            Section("Share") {
                HStack {
                    Text("Existing share")
                    Spacer()
                    Text(canFetchShare ? "Share exists" : "Share missing")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Share record")
                    Spacer()
                    Text(shareRecordName ?? "None")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Section("Last error") {
                Text(lastError ?? "None")
                    .foregroundStyle(lastError == nil ? Color.secondary : Color.red)
                    .font(.footnote)
            }
        }
        .navigationTitle("Share Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let household else { return }
            if let share = try? CloudSharing.fetchShare(for: household.objectID, persistentContainer: persistentContainer) {
                canFetchShare = true
                shareRecordName = share.recordID.recordName
            }
        }
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
