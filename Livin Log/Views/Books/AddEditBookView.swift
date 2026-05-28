import SwiftUI
import CoreData

struct AddEditBookView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState

    let household: Household
    let selectedMember: HouseholdMember?
    let editingBook: BookEntry?

    @State private var title = ""
    @State private var author = ""
    @State private var ratingText = ""
    @State private var notes = ""
    @State private var spiceLevel = 0
    @State private var bookLength = ""
    @State private var finishedAt = Date()
    @State private var coverURLString = ""
    @State private var isLookingUpCover = false
    @State private var errorMessage: String?

    init(household: Household, selectedMember: HouseholdMember?, editingBook: BookEntry? = nil) {
        self.household = household
        self.selectedMember = selectedMember
        self.editingBook = editingBook
    }

    private var canEdit: Bool {
        guard let selectedMember else { return false }
        return IdentityStore.canAct(as: selectedMember, appUser: appState.appUser, context: context)
    }

    private var parsedRating: Double? {
        let normalized = ratingText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, let value = Double(normalized) else { return nil }
        guard (0...10).contains(value) else { return nil }
        return value
    }

    var body: some View {
        Form {
            Section("Book") {
                TextField("Title", text: $title)
                TextField("Author", text: $author)

                if isLookingUpCover {
                    ProgressView("Looking up cover…")
                        .font(.caption)
                }
            }

            Section("Details") {
                TextField("Rating (0.00 - 10.00)", text: $ratingText)
                    .keyboardType(.decimalPad)
                Text("Decimal rating out of 10 (e.g., 7.23)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper("Spice Level: \(spiceLevel)", value: $spiceLevel, in: 0...5)
                TextField("Book Length (e.g., 420 pages)", text: $bookLength)
                DatePicker("Finished", selection: $finishedAt, displayedComponents: .date)
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 120)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(editingBook == nil ? "Add Book" : "Edit Book")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveBook()
                }
                .disabled(!canEdit || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedRating == nil)
            }
        }
        .task(id: "\(title)|\(author)") {
            await lookupCover()
        }
        .onAppear {
            if let editingBook {
                title = editingBook.title ?? ""
                author = editingBook.author ?? ""
                ratingText = String(format: "%.2f", editingBook.rating)
                notes = editingBook.notes ?? ""
                spiceLevel = Int(editingBook.spiceLevel)
                bookLength = editingBook.bookLength ?? ""
                finishedAt = editingBook.finishedAt ?? Date()
                coverURLString = editingBook.value(forKey: "coverURL") as? String ?? ""
            } else if ratingText.isEmpty {
                ratingText = "0.00"
            }
        }
    }


    private func lookupCover() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedAuthor.isEmpty else {
            if editingBook == nil { coverURLString = "" }
            return
        }

        isLookingUpCover = true
        let fetched = await OpenLibraryCoverService.coverURL(title: trimmedTitle, author: trimmedAuthor)
        coverURLString = fetched?.absoluteString ?? ""
        isLookingUpCover = false
    }

    private func saveBook() {
        errorMessage = nil

        guard let selectedMember else {
            errorMessage = "Choose your member profile before saving a book."
            return
        }
        guard let appUser = appState.appUser else {
            errorMessage = "Sign in is required before saving a book."
            return
        }
        guard let rating = parsedRating else {
            errorMessage = "Enter a rating between 0 and 10."
            return
        }
        guard let scopedHousehold = activeHouseholdInContext(household, context: context),
              let scopedMember = try? context.existingObject(with: selectedMember.objectID) as? HouseholdMember else {
            errorMessage = "Could not resolve your household member profile."
            return
        }
        guard scopedMember.household?.objectID == scopedHousehold.objectID else {
            errorMessage = "That member profile does not belong to this household."
            return
        }
        guard IdentityStore.canAct(as: scopedMember, appUser: appUser, context: context) else {
            errorMessage = "You can add books only to your own claimed member profile."
            print("🚫 [BookSave] denied: unresolved actor/member or attempted write to another member")
            return
        }

        if let editingBook,
           let existingOwner = editingBook.ownerMember,
           existingOwner.objectID != scopedMember.objectID {
            errorMessage = "You can edit books only on your own claimed member profile."
            print("🚫 [BookSave] denied: attempted edit of another member's book")
            return
        }

        do {
            let scopedUser = try IdentityStore.storeScopedAppUser(matching: appUser, household: scopedHousehold, context: context)
            let entry = editingBook ?? BookEntry(context: context)
            if let store = scopedHousehold.objectID.persistentStore, entry.isInserted {
                context.assign(entry, to: store)
            }

            entry.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.rating = rating
            entry.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.spiceLevel = Int16(spiceLevel)
            entry.bookLength = bookLength.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.finishedAt = finishedAt
            entry.setValue(coverURLString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "coverURL")
            entry.household = scopedHousehold
            entry.ownerMember = scopedMember
            entry.ownerAppUser = scopedUser
            entry.setValue(scopedHousehold.id, forKey: "householdId")
            entry.setValue(scopedMember.id, forKey: "ownerMemberId")
            entry.setValue(IdentityStore.durableUserId(for: scopedUser), forKey: "ownerAppUserId")

            try context.save()
            print("✅ [BookSave] saved title=\(entry.title ?? "Untitled") household=\(scopedHousehold.name ?? "Household") member=\(scopedMember.displayName ?? "Member")")
            dismiss()
        } catch {
            context.rollback()
            errorMessage = "Could not save book: \(error.localizedDescription)"
            print("❌ [BookSave] save failed: \(error)")
        }
    }
}
