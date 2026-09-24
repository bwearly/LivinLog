//
//  HouseholdRosterStepView.swift
//  Livin Log
//
//  Onboarding step 4 ("Who else lives here?"). Lists the household's members (reactive via
//  @FetchRequest, so it also reflects a member the leader just added) with a status tag and,
//  where eligible, an Invite action -- see MemberStatus/InviteMemberButton (Phase 3b).

import SwiftUI
import CoreData

struct HouseholdRosterStepView: View {
    let household: Household
    let onFinished: () -> Void

    @EnvironmentObject private var appState: AppState
    @FetchRequest private var fetchedMembers: FetchedResults<HouseholdMember>

    @State private var showingAddMember = false

    init(household: Household, onFinished: @escaping () -> Void) {
        self.household = household
        self.onFinished = onFinished
        _fetchedMembers = FetchRequest(
            entity: HouseholdMember.entity(),
            sortDescriptors: [NSSortDescriptor(key: "createdAt", ascending: true)],
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                householdScopedPredicate(household, idKey: "householdId"),
                NSPredicate(format: "isActive == YES")
            ])
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(Array(fetchedMembers)) { member in
                        memberRow(member)
                    }
                } header: {
                    Text("Who else lives here?")
                } footer: {
                    Text("You can add or invite more people any time from Settings.")
                }
            }
            .listStyle(.insetGrouped)

            VStack(spacing: 10) {
                Button {
                    showingAddMember = true
                } label: {
                    Label("Add Member", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button("Continue") {
                    onFinished()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Button("Skip for now") {
                    onFinished()
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Your Household")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddMember) {
            AddMemberSheet(household: household) { _ in }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: HouseholdMember) -> some View {
        let status = MemberStatus.resolve(for: member, currentUserRecordName: appState.currentUserRecordName)

        HStack(spacing: 12) {
            MemberAvatarBadge(name: member.displayName ?? "?", avatar: member.value(forKey: "avatar") as? String)

            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName ?? "Unnamed")
                    .font(.headline)
                Text(status.isLeader ? "\(status.label) · Leader" : status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if MemberStatus.isInviteEligible(member) {
                InviteMemberButton(member: member, household: household, isResend: status.kind == .invited)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
