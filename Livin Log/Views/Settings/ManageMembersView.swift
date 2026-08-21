//
//  ManageMembersView.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI
import CoreData

struct ManageMembersView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState

    let household: Household?

    // Reactive: re-fires automatically when a member's row (e.g. an accepted invitee's
    // HouseholdMember) merges in via CloudKit import, instead of only on the next body
    // re-evaluation triggered for some unrelated reason.
    @FetchRequest private var fetchedMembers: FetchedResults<HouseholdMember>

    @State private var showingAdd = false
    @State private var addName = ""
    @State private var errorText: String?

    init(household: Household?) {
        self.household = household
        let sortDescriptors = [
            NSSortDescriptor(
                key: "displayName",
                ascending: true,
                selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
            )
        ]
        if let household {
            // Roster context: departed members (isActive == NO) are excluded.
            _fetchedMembers = FetchRequest(
                entity: HouseholdMember.entity(),
                sortDescriptors: sortDescriptors,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    householdScopedPredicate(household, idKey: "householdId"),
                    NSPredicate(format: "isActive == YES")
                ])
            )
        } else {
            _fetchedMembers = FetchRequest(
                entity: HouseholdMember.entity(),
                sortDescriptors: sortDescriptors,
                predicate: NSPredicate(value: false)
            )
        }
    }

    private var canWrite: Bool {
        appState.isCurrentMemberAuthorized()
    }

    var body: some View {
        List {
            if let errorText {
                Section {
                    Text(errorText)
                        .foregroundStyle(.red)
                }
            }

            if household == nil {
                ContentUnavailableView("No household selected", systemImage: "person.3")
            } else {
                let members = Array(fetchedMembers)

                if members.isEmpty {
                    ContentUnavailableView("No members yet", systemImage: "person.3")
                } else {
                    membersListSection(members)
                }
            }
        }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(
            leading: editButtonView,
            trailing: addButtonView
        )
        .alert("Add Member", isPresented: $showingAdd) {
            TextField("Name", text: $addName)

            Button("Cancel", role: .cancel) {
                addName = ""
            }

            Button("Add") {
                addMember()
            }
            .disabled(addName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(household == nil ? "No household selected." : "Enter a name for the new member.")
        }
    }

    @ViewBuilder
    private func membersListSection(_ members: [HouseholdMember]) -> some View {
        if canWrite {
            ForEach(members) { member in
                memberRow(member)
            }
            .onDelete(perform: deleteMembers)
        } else {
            ForEach(members) { member in
                memberRow(member)
            }
        }
    }

    private func memberRow(_ member: HouseholdMember) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName ?? "Unnamed")
                    .font(.headline)

                Text("Member")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var editButtonView: some View {
        EditButton()
            .disabled(!canWrite)
    }

    private var addButtonView: some View {
        Button {
            showingAdd = true
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add Member")
        .disabled(household == nil || !canWrite)
    }

    // MARK: - Mutations

    private func addMember() {
        guard canWrite else { return }
        errorText = nil
        guard let household else { return }

        let trimmed = addName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else { return }

        let member = HouseholdMember(context: context)
        if let store = scopedHousehold.objectID.persistentStore {
            context.assign(member, to: store)
        }
        member.id = UUID()
        member.displayName = trimmed
        member.createdAt = Date()
        member.household = scopedHousehold
        member.setValue(scopedHousehold.id, forKey: "householdId")

        do {
            try context.save()
            #if DEBUG
            debugLogHouseholdAssignment(entityName: "HouseholdMember", object: member, household: scopedHousehold, context: context)
            #endif
            addName = ""
        } catch {
            context.rollback()
            errorText = error.localizedDescription
            print("Add member failed:", error)
        }
    }

    private func deleteMembers(offsets: IndexSet) {
        guard canWrite else { return }
        errorText = nil
        let members = Array(fetchedMembers)

        offsets.map { members[$0] }.forEach(context.delete)

        do {
            try context.save()
        } catch {
            context.rollback()
            errorText = error.localizedDescription
            print("Delete member failed:", error)
        }
    }
}
