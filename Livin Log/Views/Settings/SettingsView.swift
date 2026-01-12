//
//  SettingsView.swift
//  Keeply
//

import SwiftUI
import CoreData
import CloudKit
import MessageUI
import UIKit

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
    @State private var shareTimeoutTask: Task<Void, Never>?

    // ✅ Invite capability diagnostics
    @State private var canSendText: Bool = false
    @State private var canSendMail: Bool = false

    // ✅ Fallback invite link share
    @State private var showingInviteLinkSheet = false
    @State private var inviteURL: URL?

    // ✅ SINGLE SOURCE OF TRUTH for the sheet:
    // If this is non-nil, the sheet shows. If nil, it dismisses.
    @State private var shareSheetModel: ShareSheetModel?

    private let persistentContainer = PersistenceController.shared.container // NSPersistentCloudKitContainer

    var body: some View {
        Form {
            householdSection
            shareStatusSection
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
        .sheet(item: $shareSheetModel, onDismiss: {
            // cleanup
            isSharing = false
        }) { model in
            CloudKitShareSheet(
                share: model.share,
                container: model.container,
                onDone: {
                    shareSheetModel = nil
                    isSharing = false
                    reloadShareStatus()
                },
                onError: { err in
                    shareErrorText = err.localizedDescription
                    lastCloudKitError = err.localizedDescription
                    shareSheetModel = nil
                    isSharing = false
                }
            )
            .ignoresSafeArea()
            .onAppear {
                print("✅ CloudKitShareSheet presented with NON-NIL share+container")
            }
        }
        .sheet(isPresented: $showingInviteLinkSheet) {
            if let inviteURL {
                ActivityView(items: [inviteURL])
                    .ignoresSafeArea()
            } else {
                Text("Invite link not available yet.")
                    .padding()
            }
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

                Button {
                    if let url = share?.url {
                        inviteURL = url
                        showingInviteLinkSheet = true
                    } else {
                        shareErrorText = "Invite link isn’t available yet. Try Invite Member first, then come back."
                        lastCloudKitError = shareErrorText
                    }
                } label: {
                    HStack {
                        Text("Share Invite Link")
                        Spacer()
                        Image(systemName: "link")
                    }
                }
                .disabled(share == nil)

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
            } else {
                Text("No sharing errors.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
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
        guard let household else { return }

        shareErrorText = nil
        lastCloudKitError = nil

        // reset sheet (forces fresh present)
        shareSheetModel = nil

        isSharing = true

        print("ℹ️ Preparing CloudKit share for household:", household.objectID)

        // timeout safety
        shareTimeoutTask?.cancel()
        shareTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isSharing else { return }
                shareErrorText = "Invite is taking too long. Check iCloud and try again."
                lastCloudKitError = shareErrorText
                isSharing = false
            }
        }

        Task { @MainActor in
            do {
                // Fetch household safely on MOC queue
                let hh: Household = try await withCheckedThrowingContinuation { cont in
                    context.perform {
                        do {
                            guard let obj = try context.existingObject(with: household.objectID) as? Household else {
                                throw NSError(domain: "SettingsView", code: 1, userInfo: [NSLocalizedDescriptionKey: "Household not found"])
                            }
                            cont.resume(returning: obj)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }

                let share = try await CloudSharing.fetchOrCreateShare(
                    for: hh,
                    in: context,
                    persistentContainer: persistentContainer
                )

                // Ensure title
                let title = (hh.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? (hh.name ?? "Household")
                : "Household"

                if (share[CKShare.SystemFieldKey.title] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    share[CKShare.SystemFieldKey.title] = title as CKRecordValue
                }

                let container = CloudSharing.cloudKitContainer(from: persistentContainer)

                print("✅ Share prepared:", share.recordID.recordName)

                // Update invite capabilities right before presentation
                canSendText = MFMessageComposeViewController.canSendText()
                canSendMail = MFMailComposeViewController.canSendMail()
                print("📨 canSendText:", canSendText, "✉️ canSendMail:", canSendMail)

                shareTimeoutTask?.cancel()
                shareTimeoutTask = nil

                // ✅ THIS is what presents the sheet (only after we have share+container)
                shareSheetModel = ShareSheetModel(share: share, container: container)

            } catch {
                shareTimeoutTask?.cancel()
                shareTimeoutTask = nil

                print("🟥 Share prepare failed:", error)
                shareErrorText = error.localizedDescription
                lastCloudKitError = error.localizedDescription
                isSharing = false
            }
        }
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
}

// ✅ Identifiable model that *contains* the values the sheet needs.
private struct ShareSheetModel: Identifiable {
    let id: String
    let share: CKShare
    let container: CKContainer

    init(share: CKShare, container: CKContainer) {
        self.share = share
        self.container = container
        self.id = share.recordID.recordName
    }
}

// ✅ Fallback activity sheet for sharing a URL (invite link)
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
