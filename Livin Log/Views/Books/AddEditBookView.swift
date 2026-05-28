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
    @State private var coverID: Int?
    @State private var isbn = ""
    @State private var firstPublishYear: Int?
    @State private var searchResults: [OpenLibraryBookResult] = []
    @State private var isSearchingBooks = false
    @State private var searchMessage: String?
    @State private var selectedResultKey: String?
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
                HStack(alignment: .top, spacing: 12) {
                    BookCoverArtwork(urlString: coverURLString, size: CGSize(width: 64, height: 92))

                    VStack(spacing: 10) {
                        TextField("Title", text: $title)
                        TextField("Author", text: $author)
                    }
                }

                if let firstPublishYear {
                    LabeledContent("First published", value: String(firstPublishYear))
                }
                if !isbn.isEmpty {
                    LabeledContent("ISBN", value: isbn)
                }

                if isSearchingBooks {
                    ProgressView("Searching books…")
                        .font(.caption)
                } else if let searchMessage {
                    Text(searchMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !searchResults.isEmpty {
                Section("Book Search Results") {
                    ForEach(searchResults) { result in
                        Button {
                            applySearchResult(result)
                        } label: {
                            OpenLibraryResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                    }
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
            await searchBooksDebounced()
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
                coverID = (editingBook.value(forKey: "coverID") as? NSNumber)?.intValue
                isbn = editingBook.value(forKey: "isbn") as? String ?? ""
                firstPublishYear = (editingBook.value(forKey: "firstPublishYear") as? NSNumber)?.intValue
            } else if ratingText.isEmpty {
                ratingText = "0.00"
            }
        }
    }


    private func searchBooksDebounced() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningfulTitleCount = trimmedTitle.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }.count

        guard meaningfulTitleCount >= 3 else {
            searchResults = []
            searchMessage = trimmedTitle.isEmpty ? nil : "Type at least 3 characters to search Open Library."
            isSearchingBooks = false
            return
        }

        do {
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        isSearchingBooks = true
        searchMessage = nil

        do {
            let results = try await OpenLibraryCoverService.search(title: trimmedTitle, author: trimmedAuthor)
            guard !Task.isCancelled else { return }
            searchResults = results
            if results.isEmpty {
                searchMessage = "No Open Library matches yet. You can still save manually."
            }
            if coverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               selectedResultKey == nil,
               let firstCover = results.first(where: { $0.coverURL != nil }) {
                coverID = firstCover.coverID
                coverURLString = firstCover.coverURL?.absoluteString ?? ""
            }
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
            searchMessage = "Book search is temporarily unavailable. You can still enter details manually."
#if DEBUG
            print("📚 [BookSearch] active search failed: \(error)")
#endif
        }

        isSearchingBooks = false
    }

    private func applySearchResult(_ result: OpenLibraryBookResult, updateTextFields: Bool = true) {
        selectedResultKey = result.key
        if updateTextFields {
            title = result.title
            author = result.author == "Unknown author" ? "" : result.author
        }
        firstPublishYear = result.firstPublishYear
        coverID = result.coverID
        isbn = result.isbn ?? ""
        coverURLString = result.coverURL?.absoluteString ?? ""
        searchMessage = nil
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
            let entry: BookEntry
            if let editingBook {
                guard let existing = try context.existingObject(with: editingBook.objectID) as? BookEntry else {
                    errorMessage = "Could not resolve the book being edited."
                    return
                }
                entry = existing
            } else {
                entry = BookEntry(context: context)
            }
            try context.assign(entry, toSameStoreAs: scopedHousehold, referenceLabel: "active household")

            entry.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.rating = rating
            entry.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.spiceLevel = Int16(spiceLevel)
            entry.bookLength = bookLength.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.finishedAt = finishedAt
            entry.setValue(coverURLString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "coverURL")
            entry.setValue(coverID.map { NSNumber(value: $0) }, forKey: "coverID")
            entry.setValue(isbn.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "isbn")
            entry.setValue(firstPublishYear.map { NSNumber(value: $0) }, forKey: "firstPublishYear")
            entry.household = scopedHousehold
            entry.ownerMember = scopedMember
            entry.ownerAppUser = scopedUser
            entry.setValue(scopedHousehold.id, forKey: "householdId")
            entry.setValue(scopedMember.id, forKey: "ownerMemberId")
            entry.setValue(IdentityStore.durableUserId(for: scopedUser), forKey: "ownerAppUserId")

            let objectsToValidate: [(String, NSManagedObject?)] = [
                ("book", entry),
                ("household", scopedHousehold),
                ("ownerMember", scopedMember),
                ("ownerAppUser", scopedUser)
            ]
            context.debugLogStoreSafeSave(entityName: "BookEntry", household: scopedHousehold, member: scopedMember, objects: objectsToValidate)
            try context.validateSamePersistentStore(objectsToValidate)

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


private struct OpenLibraryResultRow: View {
    let result: OpenLibraryBookResult

    var body: some View {
        HStack(spacing: 12) {
            BookCoverArtwork(urlString: result.coverURL?.absoluteString ?? "", size: CGSize(width: 42, height: 62))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(result.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let firstPublishYear = result.firstPublishYear {
                    Text("First published \(String(firstPublishYear))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct BookCoverArtwork: View {
    let urlString: String
    let size: CGSize

    var body: some View {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color.indigo.opacity(0.25), Color.purple.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let url = URL(string: trimmed), !trimmed.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "book.closed.fill")
                .font(.title3)
            Text("Book")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }
}
