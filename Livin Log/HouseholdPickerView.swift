//
//  HouseholdPickerView.swift
//  Livin Log
//
//  Phase 3a launch routing: shown when the signed-in iCloud user is linked to more than one
//  HouseholdMember (e.g. leader of more than one household created on this account). A simple
//  picker, not the Phase 3b profile-switcher -- see AppState.Route.householdPicker.

import SwiftUI
import CoreData

struct HouseholdPickerView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .padding(.top, 24)

            Text("Choose a Household")
                .font(.title2).bold()

            Text("This iCloud account is linked to more than one household.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            List(appState.linkedMembers, id: \.objectID) { member in
                Button {
                    appState.selectLinkedMember(member)
                } label: {
                    HStack(spacing: 12) {
                        MemberAvatarBadge(name: member.displayName ?? "?", avatar: member.value(forKey: "avatar") as? String)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.household?.name ?? "Household")
                                .font(.headline)
                            Text("as \(member.displayName ?? "Member")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.insetGrouped)
        }
    }
}
