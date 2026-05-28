import SwiftUI
import CoreData

struct BookDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState

    let book: BookEntry
    let household: Household

    @State private var showingEdit = false
    @State private var showingDeleteConfirm = false
    @State private var deleteErrorMessage: String?

    private var ownerMember: HouseholdMember? {
        book.ownerMember
    }

    private var canEdit: Bool {
        IdentityStore.canAct(as: ownerMember, appUser: appState.appUser, context: context)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    BookCoverArtwork(urlString: book.value(forKey: "coverURL") as? String ?? "", size: CGSize(width: 150, height: 220))
                    Spacer()
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section("Book") {
                LabeledContent("Title", value: displayValue(book.title))
                LabeledContent("Author", value: displayValue(book.author))
                LabeledContent("Rating", value: String(format: "%.2f/10", book.rating))
            }

            Section("Details") {
                LabeledContent("Spice Level", value: "\(Int(book.spiceLevel))/5")
                LabeledContent("Book Length", value: displayValue(book.bookLength))

                if let finishedAt = book.finishedAt {
                    LabeledContent("Finished", value: finishedAt.formatted(date: .abbreviated, time: .omitted))
                }

                if let firstPublishYear = (book.value(forKey: "firstPublishYear") as? NSNumber)?.intValue {
                    LabeledContent("First Published", value: String(firstPublishYear))
                }

                if let isbn = book.value(forKey: "isbn") as? String, !isbn.isEmpty {
                    LabeledContent("ISBN", value: isbn)
                }

                if let createdAt = book.createdAt {
                    LabeledContent("Added", value: createdAt.formatted(date: .abbreviated, time: .omitted))
                }
            }

            if let notes = book.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Notes") {
                    Text(notes)
                        .foregroundStyle(.secondary)
                }
            }

            if canEdit {
                Section {
                    Button("Delete Book", role: .destructive) {
                        showingDeleteConfirm = true
                    }
                }
            }
        }
        .navigationTitle("Book")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") {
                    showingEdit = true
                }
                .disabled(!canEdit)
            }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                AddEditBookView(household: household, selectedMember: ownerMember, editingBook: book)
            }
        }
        .confirmationDialog(
            "Delete this book?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteBook()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Could Not Delete Book", isPresented: Binding(get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "The book could not be deleted.")
        }
    }

    private func deleteBook() {
        guard canEdit else {
            deleteErrorMessage = "You can delete only books on your own claimed member profile."
            return
        }

        do {
            context.delete(book)
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            deleteErrorMessage = "Could not delete book: \(error.localizedDescription)"
            print("❌ [BookDelete] delete failed: \(error)")
        }
    }

    private var coverURL: URL? {
        let s = (book.value(forKey: "coverURL") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: s)
    }

    private func displayValue(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }
}
