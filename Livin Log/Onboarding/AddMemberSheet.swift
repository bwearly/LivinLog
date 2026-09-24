//
//  AddMemberSheet.swift
//  Livin Log
//
//  Onboarding "Who else lives here?" step, and Settings' "Add member": creates a HouseholdMember
//  with no linked iCloud user. `hasOwnIPhone` is a real synced field (Phase 3b) -- it drives the
//  Invite button/status label everywhere this member shows up, not just this onboarding session.

import SwiftUI

struct AddMemberSheet: View {
    let household: Household
    let onAdded: (HouseholdMember) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var name = ""
    @State private var avatar: MemberAvatarColor = .default
    @State private var hasOwnPhone = true
    @State private var errorText: String?
    @State private var isSaving = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                }

                Section("Color") {
                    MemberAvatarColorPicker(selection: $avatar)
                }

                Section {
                    Toggle("Has their own iPhone", isOn: $hasOwnPhone)
                } footer: {
                    Text(hasOwnPhone
                         ? "You can send them an invite after adding them."
                         : "Ratings and entries can still be attributed to them without their own device.")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addMember() }
                        .disabled(trimmedName.isEmpty || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func addMember() {
        errorText = nil
        isSaving = true
        defer { isSaving = false }

        do {
            let member = try appState.addRosterMember(named: trimmedName, avatar: avatar.rawValue, hasOwnIPhone: hasOwnPhone, in: household)
            onAdded(member)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
