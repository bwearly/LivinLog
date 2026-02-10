//
//  OnboardingView.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//


import SwiftUI
import CoreData
import CloudKit

struct OnboardingView: View {
    @Environment(\.managedObjectContext) private var context

    @State private var householdName: String = "Our Household"
    @State private var myName: String = ""
    @State private var isCreating = false
    @State private var errorText: String?

    let onFinished: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "person.2.fill")
                    .font(.system(size: 44))

                Text("Welcome to Livin Log")
                    .font(.title2).bold()

                Text("Create a household to start tracking movies together. You can invite your spouse after you create it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

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
                .disabled(myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)

                // Join is Phase 2: accepts CloudKit share
                Button {
                    errorText = "Joining via invite is next — we’ll add the Share/Accept flow right after the Movies list is in."
                } label: {
                    Text("Join Household (Invite)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func createHousehold() async {
        isCreating = true
        errorText = nil
        defer { isCreating = false }

        let trimmedName = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHousehold = householdName.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let household = Household(context: context)
            household.name = trimmedHousehold.isEmpty ? "Our Household" : trimmedHousehold
            // id/createdAt are set by awakeFromInsert if you kept that file

            let member = HouseholdMember(context: context)
            member.displayName = trimmedName
            member.household = household
            // id/createdAt are set by awakeFromInsert

            try context.save()
            onFinished()
        } catch {
            errorText = "Could not create household: \(error.localizedDescription)"
        }
    }
}
