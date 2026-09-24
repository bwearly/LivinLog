//
//  EditProfileView.swift
//  Livin Log
//
//  Settings > You: edits the current user's own HouseholdMember (displayName + avatar color).
//  Both fields are already in OutboundChangeTracker.mappedProperties, so a plain save syncs.

import SwiftUI

struct EditProfileView: View {
    let member: HouseholdMember

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var name: String
    @State private var avatar: MemberAvatarColor
    @State private var errorText: String?

    init(member: HouseholdMember) {
        self.member = member
        _name = State(initialValue: member.displayName ?? "")
        _avatar = State(initialValue: MemberAvatarColor.from(member.value(forKey: "avatar") as? String))
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedName != (member.displayName ?? "")
            || avatar != MemberAvatarColor.from(member.value(forKey: "avatar") as? String)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    MemberAvatarBadge(name: trimmedName, avatar: avatar.rawValue, diameter: 64)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section("Name") {
                TextField("Name", text: $name)
                    .textContentType(.name)
            }

            Section("Color") {
                MemberAvatarColorPicker(selection: $avatar)
            }

            if let errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Your Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(trimmedName.isEmpty || !hasChanges)
            }
        }
    }

    private func save() {
        errorText = nil
        do {
            try appState.updateOwnProfile(name: trimmedName, avatar: avatar.rawValue)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
