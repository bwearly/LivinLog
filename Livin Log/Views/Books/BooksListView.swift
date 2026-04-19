import SwiftUI
import CoreData

struct BooksListView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState

    let household: Household

    @State private var selectedMemberID: NSManagedObjectID?
    @State private var showAdd = false

    private var members: [HouseholdMember] {
        let req = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        req.predicate = NSPredicate(format: "household == %@", household)
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return (try? context.fetch(req)) ?? []
    }

    private var selectedMember: HouseholdMember? {
        guard let selectedMemberID else { return members.first }
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
                    selectedMemberID ?? members.first?.objectID
                }, set: { selectedMemberID = $0 })) {
                    ForEach(members, id: \.objectID) { member in
                        Text(member.displayName ?? "Member").tag(Optional(member.objectID))
                    }
                }
                .pickerStyle(.segmented)
            }

            if books.isEmpty {
                Text("No books added yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(books) { book in
                    NavigationLink {
                        BookDetailView(book: book, household: household)
                    } label: {
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
                .onDelete { offsets in
                    guard canEditSelectedMember else { return }
                    for index in offsets where books.indices.contains(index) {
                        context.delete(books[index])
                    }
                    try? context.save()
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
        .onAppear {
            if selectedMemberID == nil {
                selectedMemberID = appState.member?.objectID ?? members.first?.objectID
            }
        }
    }
}
