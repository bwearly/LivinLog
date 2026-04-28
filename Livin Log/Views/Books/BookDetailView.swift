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

    private var ownerMember: HouseholdMember? {
        book.ownerMember
    }

    private var canEdit: Bool {
        IdentityStore.canAct(as: ownerMember, appUser: appState.appUser, context: context)
    }

    var body: some View {
        List {
            if let url = coverURL {
                Section {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        default:
                            RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemFill))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
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
    }

    private func deleteBook() {
        guard canEdit else { return }
        context.delete(book)
        try? context.save()
        dismiss()
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
