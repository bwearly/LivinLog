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
        .onAppear {
            if let editingBook {
                title = editingBook.title ?? ""
                author = editingBook.author ?? ""
                ratingText = String(format: "%.2f", editingBook.rating)
                notes = editingBook.notes ?? ""
                spiceLevel = Int(editingBook.spiceLevel)
                bookLength = editingBook.bookLength ?? ""
                finishedAt = editingBook.finishedAt ?? Date()
            } else if ratingText.isEmpty {
                ratingText = "0.00"
            }
        }
    }

    private func saveBook() {
        guard canEdit,
              let selectedMember,
              let appUser = appState.appUser,
              let rating = parsedRating,
              let scopedHousehold = activeHouseholdInContext(household, context: context) else {
            return
        }

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
        entry.household = scopedHousehold
        entry.ownerMember = selectedMember
        entry.ownerAppUser = appUser

        try? context.save()
        dismiss()
    }
}
