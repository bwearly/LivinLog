//
//  EditProfileView.swift
//  Livin Log
//
//  Edits a HouseholdMember's profile: displayName, avatar color, and (Phase 4a) an optional
//  birthday, which Quotes uses to compute a speaker's age at the time of a quote. Used for
//  Settings > You (your own profile, pushed) and for other members from the Settings roster
//  (presented as a sheet) -- who may edit whom is AppState.canEditProfile(of:). All three
//  fields are synced HouseholdMember fields, so a plain save syncs.

import CoreData
import SwiftUI

struct EditProfileView: View {
    let member: HouseholdMember
    /// True when presented as a sheet (roster), where there's no back button to leave by.
    var showsCancel: Bool = false

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var name: String
    @State private var avatar: MemberAvatarColor
    @State private var hasBirthday: Bool
    @State private var birthday: Date
    @State private var errorText: String?

    init(member: HouseholdMember, showsCancel: Bool = false) {
        self.member = member
        self.showsCancel = showsCancel
        _name = State(initialValue: member.displayName ?? "")
        _avatar = State(initialValue: MemberAvatarColor.from(member.value(forKey: "avatar") as? String))
        let storedBirthday = member.value(forKey: "birthday") as? Date
        _hasBirthday = State(initialValue: storedBirthday != nil)
        _birthday = State(initialValue: storedBirthday ?? Date())
    }

    private var isSelf: Bool {
        member.objectID == appState.member?.objectID
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        let storedBirthday = member.value(forKey: "birthday") as? Date
        let editedBirthday = hasBirthday ? AppState.normalizedBirthday(birthday) : nil
        return trimmedName != (member.displayName ?? "")
            || avatar != MemberAvatarColor.from(member.value(forKey: "avatar") as? String)
            || editedBirthday != storedBirthday
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

            Section {
                Toggle("Birthday", isOn: $hasBirthday.animation())
                if hasBirthday {
                    DatePicker("Date", selection: $birthday, in: ...Date(), displayedComponents: .date)
                }
            } footer: {
                Text("Optional. Used to show age on quotes.")
            }

            if let errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isSelf ? "Your Profile" : (member.displayName ?? "Member"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(trimmedName.isEmpty || !hasChanges)
            }
        }
    }

    private func save() {
        errorText = nil
        do {
            try appState.updateMemberProfile(
                member,
                name: trimmedName,
                avatar: avatar.rawValue,
                birthday: hasBirthday ? birthday : nil
            )
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
