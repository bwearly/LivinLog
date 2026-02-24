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

    @Binding var household: Household?
    @Binding var member: HouseholdMember?

    @State private var errorText: String?
    @State private var shareErrorText: String?

    @State private var householdName = ""
    @State private var myName = ""

    @State private var isSharing = false

    @State private var share: CKShare?
    @State private var accountStatus: CKAccountStatus = .couldNotDetermine
    @State private var lastCloudKitError: String?

    @AppStorage("ll_notify_enabled") private var notificationsEnabled = false

    @State private var showNotificationsDeniedAlert = false

    // ✅ Invite capability diagnostics
    @State private var canSendText: Bool = false
    @State private var canSendMail: Bool = false

    // Presents Apple's official CloudKit sharing UI.
    @State private var showingCloudKitSharingSheet = false

    @AppStorage(CloudSharing.lastShareErrorDefaultsKey) private var persistedLastShareError = ""
    @AppStorage(CloudSharing.lastShareStatusDefaultsKey) private var persistedLastShareStatus = ""


    private let persistentContainer = PersistenceController.shared.container // NSPersistentCloudKitContainer

    var body: some View {
        Form {
            householdSection
            shareStatusSection
            notificationsSection
            membersSection
            howSharingWorksSection
            sharingErrorSection
            errorSection
            #if DEBUG
            debugSection
            #endif
        }
        .navigationTitle("Settings")
        .onAppear {
            if let hh = household { ensureDefaultMemberExists(in: hh) }
            reloadShareStatus()
            loadAccountStatus()

            // Invite capabilities (device-level)
            canSendText = MFMessageComposeViewController.canSendText()
            canSendMail = MFMailComposeViewController.canSendMail()
            print("📨 canSendText:", canSendText, "✉️ canSendMail:", canSendMail)
        }
        .onChange(of: household?.objectID) { _, _ in
            if let hh = household { ensureDefaultMemberExists(in: hh) }
            reloadShareStatus()
        }
        .sheet(isPresented: $showingCloudKitSharingSheet, onDismiss: {
            isSharing = false
            reloadShareStatus()
        }) {
            if let household {
                // Replaced old custom "copy/send invite link" flow with Apple's CloudKit sharing controller.
                CloudKitHouseholdSharingSheet(
                    household: household,
                    onDone: {
                        showingCloudKitSharingSheet = false
                    },
                    onError: { error in
                        let message = error.localizedDescription
                        shareErrorText = message
                        lastCloudKitError = message
                        persistedLastShareError = message
                        CloudSharing.saveLastShareError(message)
                        showingCloudKitSharingSheet = false
                        isSharing = false
                    }
                )
                .ignoresSafeArea()
            }
        }
        .alert("Notifications Disabled", isPresented: $showNotificationsDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Notifications are currently disabled for Livin Log. Go to Notifications → Open iPhone Settings to enable them.")
        }
    }

    // MARK: - Sections

    private var householdSection: some View {
        Section("Household") {
            if let household {
                VStack(alignment: .leading, spacing: 6) {
                    Text(household.name ?? "Household")
                        .font(.headline)

                    Text("Sharing uses iCloud")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }

                Button {
                    inviteMember()
                } label: {
                    HStack {
                        Text(isSharing ? "Preparing invite..." : "Invite Member")
                        Spacer()
                        if isSharing {
                            ProgressView()
                        } else {
                            Image(systemName: "person.badge.plus")
                        }
                    }
                }
                .disabled(isSharing)

                // Old "Share Invite Link" action removed: we only use CloudKit's official invite flow.

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

    private var shareStatusSection: some View {
        Section("Share Status") {
            HStack {
                Text("iCloud account")
                Spacer()
                Text(accountStatusText(accountStatus))
                    .foregroundStyle(.secondary)
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
                    Text("Not yet")
                        .foregroundStyle(.secondary)
                }
            }

            if !persistedLastShareStatus.isEmpty {
                HStack {
                    Text("Last status")
                    Spacer()
                    Text(persistedLastShareStatus)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

    private var howSharingWorksSection: some View {
        Section("How sharing works") {
            Text("Inviting someone creates a private iCloud share for this household. Anyone you invite can see the same household data on their device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var sharingErrorSection: some View {
        Section("Sharing") {
            if let shareErrorText {
                Text(shareErrorText)
                    .foregroundStyle(.red)
                    .font(.footnote)
            } else if !persistedLastShareError.isEmpty {
                Text(persistedLastShareError)
                    .foregroundStyle(.red)
                    .font(.footnote)
            } else {
                Text("No sharing errors.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            if household != nil {
                Button("Reset Household Share", role: .destructive) {
                    resetHouseholdShare()
                }
                .disabled(isSharing)
            }

            NavigationLink("Share Diagnostics") {
                ShareDiagnosticsView(
                    household: household,
                    accountStatus: accountStatus,
                    lastError: lastCloudKitError ?? (persistedLastShareError.isEmpty ? nil : persistedLastShareError),
                    persistentContainer: persistentContainer
                )
            }
        }
    }

    private var errorSection: some View {
        Section {
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }

    #if DEBUG
    private var debugSection: some View {
        Section("Debug") {
            HStack {
                Text("Account status")
                Spacer()
                Text(accountStatusText(accountStatus))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Can send text")
                Spacer()
                Text(canSendText ? "Yes" : "No")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Can send mail")
                Spacer()
                Text(canSendMail ? "Yes" : "No")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Last CloudKit error")
                Spacer()
                Text(lastCloudKitError ?? "None")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button("Reload share status") {
                reloadShareStatus()
                canSendText = MFMessageComposeViewController.canSendText()
                canSendMail = MFMailComposeViewController.canSendMail()
                print("📨 canSendText:", canSendText, "✉️ canSendMail:", canSendMail)
            }
        }
    }
    #endif

    // MARK: - Share handling

    private func inviteMember() {
        guard household != nil else { return }

        shareErrorText = nil
        lastCloudKitError = nil
        persistedLastShareError = ""
        persistedLastShareStatus = "Presenting CloudKit share sheet"
        CloudSharing.saveLastShareStatus("Presenting CloudKit share sheet")
        CloudSharing.saveLastShareError(nil)

        isSharing = true
        showingCloudKitSharingSheet = true
        print("ℹ️ Presenting UICloudSharingController for household invite")
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
    }

    private func loadAccountStatus() {
        Task {
            let status = await CloudSharing.accountStatus(using: persistentContainer)
            await MainActor.run { accountStatus = status }
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
        let members = fetchMembers(for: household)

        if !members.isEmpty {
            if self.member == nil {
                self.member = members.first
                SelectionStore.save(household: self.household, member: self.member)
            }
            return
        }

        let me = HouseholdMember(context: context)
        me.id = UUID()
        me.createdAt = Date()
        me.displayName = "Me"
        me.household = household

        do {
            try context.save()
            self.member = me
            SelectionStore.save(household: self.household, member: self.member)
        } catch {
            context.rollback()
            self.errorText = error.localizedDescription
        }
    }

    // MARK: - Create Household

    private func createHousehold() {
        errorText = nil

        let hhName = householdName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hhName.isEmpty else { return }

        let name = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? "Me" : name

        let hh = Household(context: context)
        hh.id = UUID()
        hh.createdAt = Date()
        hh.name = hhName

        let me = HouseholdMember(context: context)
        me.id = UUID()
        me.createdAt = Date()
        me.displayName = displayName
        me.household = hh

        do {
            try context.save()
            self.household = hh
            self.member = me
            SelectionStore.save(household: hh, member: me)

            householdName = ""
            myName = ""
        } catch {
            context.rollback()
            self.errorText = error.localizedDescription
        }
    }


    private func resetHouseholdShare() {
        guard let household else { return }

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

private struct ShareDiagnosticsView: View {
    let household: Household?
    let accountStatus: CKAccountStatus
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
            }

            Section("Share") {
                HStack {
                    Text("Existing share")
                    Spacer()
                    Text(canFetchShare ? "Yes" : "No")
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
