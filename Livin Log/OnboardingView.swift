//
//  OnboardingView.swift
//  Livin Log
//
//  Phase 3a leader onboarding: Welcome -> Name your household -> Who are you? -> Who else lives
//  here? -> dashboard. Identity is the iCloud user record name (AppState.currentUserRecordName),
//  not Sign-in-with-Apple -- there is no sign-in step here anymore.
//

import SwiftUI

private struct OnboardingTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
            }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState

    private enum Step: Equatable {
        case welcome
        case invitePlaceholder
        case householdName
        case whoAreYou
        case roster
    }

    @State private var step: Step = .welcome
    @State private var householdName: String = "Our Household"
    @State private var myName: String = ""
    @State private var myAvatar: MemberAvatarColor = .default
    @State private var isCreating = false
    @State private var errorText: String?

    let onFinished: () -> Void

    var body: some View {
        NavigationStack {
            stepContent
                .navigationTitle(title(for: step))
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .invitePlaceholder:
            invitePlaceholderStep
        case .householdName:
            householdNameStep
        case .whoAreYou:
            whoAreYouStep
        case .roster:
            if let household = appState.household {
                HouseholdRosterStepView(household: household, onFinished: onFinished)
            } else {
                // Shouldn't happen -- createInitialHousehold() sets appState.household before
                // advancing here. Defensive fallback so we never strand the user on a blank step.
                ProgressView()
                    .onAppear { step = .householdName }
            }
        }
    }

    private func title(for step: Step) -> String {
        switch step {
        case .welcome: return "Welcome"
        case .invitePlaceholder: return "Join a Household"
        case .householdName: return "Name Your Household"
        case .whoAreYou: return "Who Are You?"
        case .roster: return "Your Household"
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "house.and.flag.fill")
                .font(.system(size: 44))

            Text("Welcome to Livin Log")
                .font(.title2).bold()

            Text("Keep track of the movies, books, TV shows, and moments your household shares.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    step = .householdName
                } label: {
                    Text("Start a Household")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    step = .invitePlaceholder
                } label: {
                    Text("I Have an Invite")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Step 1b: Invite placeholder (Phase 3b builds the real flow)

    private var invitePlaceholderStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "envelope.badge.person.crop")
                .font(.system(size: 44))

            Text("Open Your Invite")
                .font(.title2).bold()

            Text("To join an existing household, open the invite link you received in Messages.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            Button("Back") {
                step = .welcome
            }
            .buttonStyle(.bordered)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Step 2: Name your household

    private var householdNameStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("What should we call your household?")
                .font(.title3).bold()
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            TextField("Household name", text: $householdName)
                .textFieldStyle(OnboardingTextFieldStyle())
                .padding(.horizontal)

            Spacer()

            Button {
                step = .whoAreYou
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .disabled(householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Step 3: Who are you

    private var whoAreYouStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("What's your name?")
                .font(.title3).bold()

            TextField("Your name", text: $myName)
                .textFieldStyle(OnboardingTextFieldStyle())
                .textContentType(.name)
                .padding(.horizontal)

            VStack(spacing: 8) {
                Text("Pick a color")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                MemberAvatarColorPicker(selection: $myAvatar)
            }

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .padding(.horizontal)
            }

            Spacer()

            Button {
                Task { await createHousehold() }
            } label: {
                if isCreating {
                    ProgressView()
                } else {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .disabled(myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            .padding(.bottom, 24)
        }
    }

    private func createHousehold() async {
        isCreating = true
        errorText = nil
        defer { isCreating = false }

        do {
            try appState.createInitialHousehold(householdName: householdName, memberName: myName, avatar: myAvatar.rawValue)
            step = .roster
        } catch {
            errorText = "Could not create household: \(error.localizedDescription)"
        }
    }
}
