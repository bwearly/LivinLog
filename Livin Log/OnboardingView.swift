//
//  OnboardingView.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState

    @State private var householdName: String = "Our Household"
    @State private var myName: String = ""
    @State private var isCreating = false
    @State private var showingPasteInvite = false
    @State private var pendingInvite: PendingShareInvite?
    @State private var errorText: String?

    let onFinished: () -> Void

    private var isSignedIn: Bool { appState.appUser != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "person.2.fill")
                    .font(.system(size: 44))

                Text("Welcome to Livin Log")
                    .font(.title2).bold()

                if !isSignedIn {
                    Text("Sign in with Apple to securely attach your member profile across reinstall and new devices.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    SignInWithAppleButton(.signIn, onRequest: { request in
                        request.requestedScopes = [.fullName]
                    }, onCompletion: { result in
                        handleAppleSignIn(result)
                    })
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 44)
                    .padding(.horizontal)
                } else {
                    Text("Create a household or join with an invite.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                VStack(spacing: 10) {
                    TextField("Your name (e.g., Blake)", text: $myName)
                        .textFieldStyle(.roundedBorder)

                    TextField("Household name", text: $householdName)
                        .textFieldStyle(.roundedBorder)
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
                .disabled(!isSignedIn || myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)

                Button {
                    showingPasteInvite = true
                } label: {
                    Text("Join Household (Invite)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .disabled(!isSignedIn)

                Spacer()
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showingPasteInvite) {
            PasteInviteLinkSheet { invite in
                pendingInvite = invite
            }
        }
        .sheet(item: $pendingInvite) { invite in
            AcceptHouseholdInviteSheet(pendingInvite: invite) {
                onFinished()
            }
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
