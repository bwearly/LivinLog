import SwiftUI
import CoreData

struct ChildrenManagerView: View {
    @Environment(\.managedObjectContext) private var context

    let household: Household

    @FetchRequest private var children: FetchedResults<LLChild>

    @State private var showingAdd = false
    @State private var editingChild: LLChild?

    init(household: Household) {
        self.household = household
        _children = FetchRequest<LLChild>(
            sortDescriptors: [NSSortDescriptor(keyPath: \LLChild.name, ascending: true)],
            predicate: NSPredicate(format: "household == %@", household),
            animation: .default
        )
    }

    var body: some View {
        List {
            if children.isEmpty {
                ContentUnavailableView("No children yet", systemImage: "figure.and.child.holdinghands")
            }

            ForEach(children, id: \.objectID) { child in
                Button {
                    editingChild = child
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(child.nameValue)
                                .font(.headline)
                            Text(child.birthdayValue.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteChildren)
        }
        .navigationTitle("Children")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Child", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                AddEditChildView(household: household)
            }
        }
        .sheet(item: $editingChild) { child in
            NavigationStack {
                AddEditChildView(household: household, editingChild: child)
            }
        }
    }

    private func deleteChildren(at offsets: IndexSet) {
        offsets.map { children[$0] }.forEach(context.delete)

        do {
            try context.save()
        } catch {
            context.rollback()
            print("Delete child failed:", error)
        }
    }
}

private struct AddEditChildView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    let household: Household
    let editingChild: LLChild?

    @State private var name = ""
    @State private var birthday = Date()
    @State private var showingDeleteAlert = false

    init(household: Household, editingChild: LLChild? = nil) {
        self.household = household
        self.editingChild = editingChild
    }

    private var isEditing: Bool { editingChild != nil }

    var body: some View {
        Form {
            Section("Child") {
                TextField("Name", text: $name)
                DatePicker("Birthday", selection: $birthday, displayedComponents: .date)
            }

            if isEditing {
                Section {
                    Button("Delete Child", role: .destructive) {
                        showingDeleteAlert = true
                    }
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Child" : "Add Child")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .alert("Delete this child?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                delete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Linked quotes are kept, but child links are removed.")
        }
        .onAppear {
            guard let editingChild else { return }
            name = editingChild.nameValue
            birthday = editingChild.birthdayValue
        }
    }

    private func save() {
        let child = editingChild ?? LLChild(context: context)
        let now = Date()

        if child.id == nil {
            child.id = UUID()
            child.createdAt = now
        }

        child.updatedAt = now
        child.household = household
        child.nameValue = name.trimmingCharacters(in: .whitespacesAndNewlines)
        child.birthdayValue = birthday

        do {
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            print("Save child failed:", error)
        }
    }

    private func delete() {
        guard let editingChild else { return }
        context.delete(editingChild)

        do {
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            print("Delete child failed:", error)
        }
    }
}
