//
//  ClaimMemberView.swift
//  Livin Log
//
//  Phase 3b: shown for AppState.Route.claimingMember ("Which one are you?") after joining a
//  household. If the accepting participant's ID matched a member's inviteParticipantID, that
//  member is preselected ("Are you Liz?") per the Phase 3b plan; otherwise the full list of
//  unclaimed members shows directly. "I'm not listed" creates a fresh, claimed member.

import SwiftUI
import CoreData

struct ClaimMemberView: View {
    @EnvironmentObject private var appState: AppState

    @State private var showingFullList = false
    @State private var showingAddSelf = false
    @State private var errorText: String?
    @State private var isSaving = false

    private var preselectedMember: HouseholdMember? {
        guard let id = appState.preselectedClaimMemberID else { return nil }
        return appState.claimableMembers.first { $0.objectID == id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let preselected = preselectedMember, !showingFullList {
                    confirmView(preselected)
                } else {
                    listView
                }
            }
            .navigationTitle("Who Are You?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(true)
        .sheet(isPresented: $showingAddSelf) {
            if let household = appState.claimableHousehold {
                AddSelfSheet(household: household)
                    .environmentObject(appState)
            }
        }
    }

    @ViewBuilder
    private func confirmView(_ member: HouseholdMember) -> some View {
        VStack(spacing: 16) {
            Spacer()

            MemberAvatarBadge(name: member.displayName ?? "?", avatar: member.value(forKey: "avatar") as? String, diameter: 64)

            Text("Are you \(member.displayName ?? "this person")?")
                .font(.title3).bold()
                .multilineTextAlignment(.center)

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .padding(.horizontal)
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    confirm(member)
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Yes, That's Me")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)

                Button("Not Me") {
                    showingFullList = true
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private var listView: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if appState.claimableMembers.isEmpty {
                        ContentUnavailableView("No one to claim yet", systemImage: "person.crop.circle.badge.questionmark")
                    } else {
                        ForEach(appState.claimableMembers, id: \.objectID) { member in
                            Button {
                                confirm(member)
                            } label: {
                                HStack(spacing: 12) {
                                    MemberAvatarBadge(name: member.displayName ?? "?", avatar: member.value(forKey: "avatar") as? String)
                                    Text(member.displayName ?? "Unnamed")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving)
                        }
                    }
                } header: {
                    Text("Who are you?")
                }
            }
            .listStyle(.insetGrouped)

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .padding(.horizontal)
            }

            Button("I'm Not Listed") {
                showingAddSelf = true
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)
            .padding()
        }
    }

    private func confirm(_ member: HouseholdMember) {
        errorText = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try appState.claimMember(member)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct AddSelfSheet: View {
    let household: Household

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var avatar: MemberAvatarColor = .default
    @State private var errorText: String?
    @State private var isSaving = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your name") {
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
            .navigationTitle("Add Yourself")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { save() }
                        .disabled(trimmedName.isEmpty || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        errorText = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try appState.createAndClaimNewMember(named: trimmedName, avatar: avatar.rawValue, in: household)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
