//
//  DeleteHouseholdSheet.swift
//  Livin Log
//
//  Settings > Danger zone (leader only): names the other linked members who lose the household
//  too, and requires typing the household name before Delete enables.

import SwiftUI

struct DeleteHouseholdSheet: View {
    let householdName: String
    /// Display names of the other members currently linked to an iCloud account.
    let otherLinkedMemberNames: [String]
    let onDelete: () async -> String?

    @Environment(\.dismiss) private var dismiss

    @State private var typedName = ""
    @State private var isDeleting = false
    @State private var errorText: String?

    private var nameMatches: Bool {
        !householdName.isEmpty && typedName.trimmingCharacters(in: .whitespacesAndNewlines) == householdName
    }

    private var consequenceText: String {
        if otherLinkedMemberNames.isEmpty {
            return "This permanently deletes \(householdName) and everything in it."
        }
        let names = otherLinkedMemberNames.formatted(.list(type: .and))
        return "This deletes \(householdName) for everyone, including \(names). Everything in it is permanently removed."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(consequenceText)
                }

                Section {
                    TextField(householdName, text: $typedName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(isDeleting)
                } header: {
                    Text("Type \u{201C}\(householdName)\u{201D} to confirm")
                }

                Section {
                    Button(role: .destructive) {
                        delete()
                    } label: {
                        HStack {
                            Text("Delete Household")
                            if isDeleting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!nameMatches || isDeleting)
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Delete Household?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private func delete() {
        errorText = nil
        isDeleting = true
        Task {
            // On success AppState re-routes away from Settings, so there's nothing to reset.
            if let failure = await onDelete() {
                errorText = failure
                isDeleting = false
            }
        }
    }
}
