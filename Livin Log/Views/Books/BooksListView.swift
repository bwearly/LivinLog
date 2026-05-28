import SwiftUI
import CoreData

struct BooksListView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState

    let household: Household

    @State private var selectedMemberID: NSManagedObjectID?
    @State private var showAdd = false
    @State private var deleteErrorMessage: String?

    private var members: [HouseholdMember] {
        let req = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        req.predicate = NSPredicate(format: "household == %@", household)
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return (try? context.fetch(req)) ?? []
    }

    private var selectedMember: HouseholdMember? {
        guard let selectedMemberID else { return nil }
        return members.first(where: { $0.objectID == selectedMemberID })
    }

    private var canEditSelectedMember: Bool {
        guard let selectedMember else { return false }
        return IdentityStore.canAct(as: selectedMember, appUser: appState.appUser, context: context)
    }

    private var books: [BookEntry] {
        guard let selectedMember else { return [] }
        let req = NSFetchRequest<BookEntry>(entityName: "BookEntry")
        req.predicate = NSPredicate(format: "household == %@ AND ownerMember == %@", household, selectedMember)
        req.sortDescriptors = [NSSortDescriptor(key: "finishedAt", ascending: false), NSSortDescriptor(key: "createdAt", ascending: false)]
        return (try? context.fetch(req)) ?? []
    }

    var body: some View {
        List {
            if !members.isEmpty {
                Picker("Member", selection: Binding(get: {
                    selectedMemberID
                }, set: { selectedMemberID = $0 })) {
                    Text("Select profile").tag(Optional<NSManagedObjectID>.none)
                    ForEach(members, id: \.objectID) { member in
                        Text(member.displayName ?? "Member").tag(Optional(member.objectID))
                    }
                }
                .pickerStyle(.segmented)
            }

            if selectedMember == nil {
                Text("Choose a profile to view books.")
                    .foregroundStyle(.secondary)
            } else if books.isEmpty {
                Text("No books added yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(books) { book in
                    NavigationLink {
                        BookDetailView(book: book, household: household)
                    } label: {
                        HStack(spacing: 12) {
                            BookCoverArtwork(urlString: book.value(forKey: "coverURL") as? String ?? "", size: CGSize(width: 42, height: 62))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.title ?? "Untitled")
                                    .font(.headline)
                            Text(book.author ?? "Unknown author")
                                .foregroundStyle(.secondary)
                            Text(String(format: "Rating %.2f/10", book.rating))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let finishedAt = book.finishedAt {
                                Text("Finished \(finishedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    deleteBooks(at: offsets)
                }
            }
        }
        .navigationTitle("Books Read")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!canEditSelectedMember || selectedMember == nil)
            }
        }
        .navigationDestination(isPresented: $showAdd) {
            AddEditBookView(household: household, selectedMember: selectedMember)
        }
        .overlay(alignment: .bottom) {
            if selectedMember != nil && !canEditSelectedMember {
                Text("Viewing only. You can edit only your own books.")
                    .font(.footnote)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .alert("Could Not Delete Book", isPresented: Binding(get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "The selected book could not be deleted.")
        }
        .onAppear {
            if let appMemberID = appState.member?.objectID,
               members.contains(where: { $0.objectID == appMemberID }) {
                selectedMemberID = appMemberID
            } else if selectedMemberID != nil,
                      members.contains(where: { $0.objectID == selectedMemberID }) == false {
                selectedMemberID = nil
            }
        }
    }

    private func deleteBooks(at offsets: IndexSet) {
        guard canEditSelectedMember else {
            deleteErrorMessage = "You can delete only books on your own claimed member profile."
            return
        }

        do {
            for index in offsets where books.indices.contains(index) {
                context.delete(books[index])
            }
            try context.save()
        } catch {
            context.rollback()
            deleteErrorMessage = "Could not delete book: \(error.localizedDescription)"
            print("❌ [BookDelete] list delete failed: \(error)")
        }
    }
}
