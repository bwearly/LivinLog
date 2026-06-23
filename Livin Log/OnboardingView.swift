//
//  OnboardingView.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState

    @State private var householdName: String = "Our Household"
    @State private var myName: String = ""
    @State private var isCreating = false
    @State private var showingPasteInvite = false
    @State private var pendingInvite: PendingShareInvite?
    @State private var errorText: String?
    @State private var showingDifferentAppleIDConfirmation = false

    let onFinished: () -> Void

    private var isSignedIn: Bool { appState.appUser != nil }
    private var shouldShowAppleButton: Bool {
        !isSignedIn && SetupDiagnostics.signInWithAppleUIEnabled(
            isSignedIn: isSignedIn,
            household: appState.household,
            membership: appState.currentMembership
        )
    }

    private var trimmedName: String {
        myName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreateHousehold: Bool {
        isSignedIn && !trimmedName.isEmpty && !isCreating
    }

    private var appleButtonTitle: SignInWithAppleButton.Label {
        .signIn
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "person.2.fill")
                    .font(.system(size: 44))

                Text("Welcome to Livin Log")
                    .font(.title2).bold()

                if isSignedIn {
                    signedInStatusCard
                } else {
                    Text("Sign in with Apple to securely attach your member profile across reinstall and new devices.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                if shouldShowAppleButton {
                    SignInWithAppleButton(appleButtonTitle, onRequest: { request in
                        request.requestedScopes = [.fullName, .email]
                    }, onCompletion: { result in
                        handleAppleSignIn(result)
                    })
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 44)
                    .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Create a household")
                        .font(.headline)

                    TextField("Your name (required)", text: $myName)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.name)

                    TextField("Household name", text: $householdName)
                        .textFieldStyle(.roundedBorder)

                    Text("Your name is required so family members know who created the household.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .padding(.horizontal)
                }

                Button {
                    Task { await createHousehold() }
                } label: {
                    if isCreating {
                        ProgressView()
                    } else {
                        Text("Create Household")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .disabled(!canCreateHousehold)

                Button {
                    showingPasteInvite = true
                } label: {
                    Text("Join Household with Invite")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)

                if isSignedIn {
                    Divider()
                        .padding(.horizontal)

                    VStack(spacing: 8) {
                        Button("Retry iCloud Sync") {
                            Task { await appState.start(callSite: "OnboardingView.retrySync") }
                        }
                        .buttonStyle(.bordered)

                        Button("Use a Different Apple ID", role: .destructive) {
                            showingDifferentAppleIDConfirmation = true
                        }
                        .font(.footnote)
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            prefillNameIfAvailable()
            logSetupDiagnostics(reason: "onAppear")
        }
        .onChange(of: isSignedIn) { _, _ in
            prefillNameIfAvailable()
            logSetupDiagnostics(reason: "isSignedIn changed")
        }
        .onChange(of: pendingInvite?.id) { _, _ in logSetupDiagnostics(reason: "pendingInvite changed") }
        .sheet(isPresented: $showingPasteInvite) {
            PasteInviteLinkSheet(
                isSignedIn: isSignedIn,
                onInviteReady: { invite in
                    pendingInvite = invite
                },
                onInviteDeferred: { _ in
                    errorText = "Sign in with Apple to finish joining this household invite."
                }
            )
        }
        .confirmationDialog(
            "Use a Different Apple ID?",
            isPresented: $showingDifferentAppleIDConfirmation,
            titleVisibility: .visible
        ) {
            Button("Use a Different Apple ID", role: .destructive) {
                appState.resetAppleSignInSession(reason: "onboarding different Apple ID confirmation")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the Apple-linked identity saved on this device for Livin Log and returns you to sign-in/setup. It will not delete household data from iCloud or CloudKit.")
        }
        .sheet(item: $pendingInvite) { invite in
            AcceptHouseholdInviteSheet(
                pendingInvite: invite,
                onAccepted: { onFinished() },
                onCancelInvite: {
                    PendingInviteStore.clear(reason: "cancelled from onboarding accept sheet")
                    pendingInvite = nil
                },
                isSignedIn: isSignedIn
            )
        }
    }

    private var signedInStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Signed in with Apple", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)

            Text("Create a household or join one with an invite. We’ll also check iCloud for any household already linked to your account.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if appState.isWaitingForCloudKitMembershipImport {
                Label("Checking iCloud…", systemImage: "icloud.and.arrow.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func logSetupDiagnostics(reason: String) {
        SetupDiagnostics.logOnboardingScreen(
            isSignedIn: isSignedIn,
            appUser: appState.appUser,
            household: appState.household,
            member: appState.member,
            membership: appState.currentMembership,
            candidateMembershipCount: appState.candidateMemberships.count,
            isInviteFlow: pendingInvite != nil || PendingInviteStore.load() != nil,
            context: context
        )
    }

    private func prefillNameIfAvailable() {
        guard trimmedName.isEmpty else { return }
        let storedName = appState.appUser?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !storedName.isEmpty {
            myName = storedName
        }
    }

    private func createHousehold() async {
        isCreating = true
        errorText = nil
        defer { isCreating = false }

        do {
            try appState.createInitialHousehold(name: householdName, memberName: myName)
            onFinished()
        } catch {
            errorText = "Could not create household: \(error.localizedDescription)"
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .failure(let error):
            errorText = "Apple Sign-In failed: \(error.localizedDescription)"
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                errorText = "Could not read Apple credential."
                return
            }

            let given = credential.fullName?.givenName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let family = credential.fullName?.familyName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let prettyName = [given, family]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            do {
                print("🍎 [SetupDiagnostics] Apple Sign-In credential received (user id length: \(credential.user.count))")
                try appState.handleAppleSignIn(subject: credential.user, displayName: prettyName.isEmpty ? nil : prettyName)
                if myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    myName = prettyName
                }
                Task { await appState.start(callSite: "OnboardingView.appleSignIn") }
            } catch {
                errorText = "Could not finish sign-in: \(error.localizedDescription)"
            }
        }
    }
}
