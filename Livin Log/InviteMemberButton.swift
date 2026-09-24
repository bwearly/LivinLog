//
//  InviteMemberButton.swift
//  Livin Log
//
//  Phase 3b: the Invite/Resend action, reused by the onboarding roster and Settings > Members.
//  Presents the plain system share sheet (share.oneTimeURL(for:) + a short message) -- see
//  HouseholdShareManager's header comment for why this isn't UICloudSharingController.

import SwiftUI

struct InviteMemberButton: View {
    let member: HouseholdMember
    let household: Household
    var isResend: Bool = false

    @EnvironmentObject private var appState: AppState
    @State private var isPreparing = false
    @State private var shareURL: URL?
    @State private var errorText: String?

    var body: some View {
        Button {
            prepareInvite()
        } label: {
            if isPreparing {
                ProgressView()
            } else {
                Text(isResend ? "Resend" : "Invite")
            }
        }
        .disabled(isPreparing)
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL {
                ActivityShareSheet(items: [inviteMessage, shareURL]) { completed in
                    if completed {
                        appState.markInvited(member)
                    }
                }
            }
        }
        .alert("Couldn't Send Invite", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var inviteMessage: String {
        "Join \(household.name ?? "our household") on Livin Log"
    }

    private func prepareInvite() {
        errorText = nil
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                shareURL = try await appState.inviteMember(member, household: household)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
