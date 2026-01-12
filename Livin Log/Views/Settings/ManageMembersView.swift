//
//  ManageMembersView.swift
//  Keeply
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI
import CoreData

struct ManageMembersView: View {
    @Environment(\.managedObjectContext) private var context

    let household: Household?

    @State private var showingAdd = false
    @State private var addName = ""
    @State private var errorText: String?

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
                let members = fetchMembers()

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
                                    .font(.headline)
                                Text("Member")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: deleteMembers)
                }
            }
        }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Member")
                .disabled(household == nil)
            }
        }
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

    // MARK: - Fetch (reliable, CloudKit-safe)

    private func fetchMembers() -> [HouseholdMember] {
        guard let household else { return [] }

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

    // MARK: - Mutations

    private func addMember() {
        errorText = nil
        guard let household else { return }

        let trimmed = addName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let m = HouseholdMember(context: context)
        m.id = UUID()
        m.displayName = trimmed
        m.createdAt = Date()
        m.household = household

        do {
            try context.save()
            addName = ""
        } catch {
            context.rollback()
            errorText = error.localizedDescription
            print("Add member failed:", error)
        }
    }

    private func deleteMembers(offsets: IndexSet) {
        errorText = nil
        let members = fetchMembers()

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
