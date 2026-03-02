import SwiftUI
import CoreData

struct CreateMemberProfileSheet: View {
    let household: Household
    let onCreated: (HouseholdMember) -> Void

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("What should we call you?")
                    .font(.headline)

                TextField("Your name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSaving)

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    createMember()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || trimmedName.isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("Your Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createMember() {
        errorText = nil
        isSaving = true

        let member = HouseholdMember(context: context)
        member.id = UUID()
        member.createdAt = Date()
        member.displayName = trimmedName
        member.household = household

        do {
            try context.save()
            SelectionStore.save(household: household, member: member)
            SelectionStore.saveDeviceMember(member, for: household)
            print("✅ Created new member for shared household: \(trimmedName)")
            onCreated(member)
            dismiss()
        } catch {
            context.rollback()
            errorText = error.localizedDescription
        }

        isSaving = false
    }
}
