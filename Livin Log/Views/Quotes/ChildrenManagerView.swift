import SwiftUI
import CoreData

struct ChildrenManagerView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState

    let household: Household

    @FetchRequest private var children: FetchedResults<LLChild>

    @State private var showingAdd = false
    @State private var editingChild: LLChild?

    private var canWrite: Bool {
        appState.isCurrentMemberAuthorized()
    }

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
            emptyStateSection
            childrenSection
        }
        .navigationTitle("Children")
        .navigationBarItems(trailing: addButton)
        .sheet(isPresented: $showingAdd, content: addSheet)
        .sheet(item: $editingChild) { child in
            editSheet(for: child)
        }
    }

    @ViewBuilder
    private var emptyStateSection: some View {
        if children.isEmpty {
            ContentUnavailableView(
                "No children yet",
                systemImage: "figure.and.child.holdinghands"
            )
        }
    }

    private var childrenSection: some View {
        ForEach(children, id: \.objectID) { child in
            ChildRowButton(child: child) {
                editingChild = child
            }
        }
        .onDelete(perform: canWrite ? { offsets in
            deleteChildren(at: offsets)
        } : nil)
    }

    private var addButton: some View {
        Button(action: {
            showingAdd = true
        }) {
            Label("Add Child", systemImage: "plus")
        }
        .disabled(!canWrite)
    }

    private func addSheet() -> some View {
        NavigationStack {
            AddEditChildView(household: household)
        }
    }

    private func editSheet(for child: LLChild) -> some View {
        NavigationStack {
            AddEditChildView(household: household, editingChild: child)
        }
    }

    private func deleteChildren(at offsets: IndexSet) {
        guard canWrite else { return }

        let items = offsets.map { children[$0] }
        items.forEach(context.delete)

        do {
            try context.save()
        } catch {
            context.rollback()
            print("Delete child failed:", error)
        }
    }
}

private struct ChildRowButton: View {
    let child: LLChild
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
}

private struct AddEditChildView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let household: Household
    let editingChild: LLChild?

    @State private var name = ""
    @State private var birthday = Date()
    @State private var showingDeleteAlert = false

    private let persistentContainer = PersistenceController.shared.container

    private var canWrite: Bool {
        appState.isCurrentMemberAuthorized()
    }

    private var isEditing: Bool {
        editingChild != nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(household: Household, editingChild: LLChild? = nil) {
        self.household = household
        self.editingChild = editingChild
    }

    var body: some View {
        Form {
            Section("Child") {
                TextField("Name", text: $name)
                DatePicker("Birthday", selection: $birthday, displayedComponents: .date)
            }

            if isEditing {
                Section {
                    Button("Delete Child", role: .destructive, action: {
                        showingDeleteAlert = true
                    })
                    .disabled(!canWrite)
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Child" : "Add Child")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(
            leading: cancelButton,
            trailing: saveButton
        )
        .alert("Delete this child?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel, action: {})
        } message: {
            Text("Linked quotes are kept, but child links are removed.")
        }
        .onAppear(perform: loadExistingValues)
    }

    private var cancelButton: some View {
        Button("Cancel", action: {
            dismiss()
        })
    }

    private var saveButton: some View {
        Button("Save", action: save)
            .disabled(trimmedName.isEmpty || !canWrite)
    }

    private func loadExistingValues() {
        guard let editingChild else { return }
        name = editingChild.nameValue
        birthday = editingChild.birthdayValue
    }

    private func save() {
        guard canWrite else { return }
        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else { return }

        let now = Date()
        let child: LLChild

        if let editingChild,
           let existing = try? context.existingObject(with: editingChild.objectID) as? LLChild {
            child = existing
        } else {
            child = LLChild(context: context)
        }

        let store = editingChild != nil ? storeForParent(child) : scopedHousehold.objectID.persistentStore
        assignIfInserted(child, to: store, in: context)

        #if DEBUG
        print("🧩 [EditSave] entity=LLChild store=\(store?.url?.lastPathComponent ?? "nil-store") objectID=\(child.objectID.uriRepresentation().absoluteString)")
        #endif

        if child.id == nil {
            child.id = UUID()
            child.createdAt = now
        }

        child.updatedAt = now
        child.household = scopedHousehold
        child.nameValue = trimmedName
        child.birthdayValue = birthday

        do {
            try context.save()

            includeInHouseholdShare(
                persistentContainer: persistentContainer,
                household: scopedHousehold,
                objects: [child],
                label: "LLChild"
            )

            #if DEBUG
            debugPrintHouseholdDiagnostics(household: scopedHousehold, context: context, reason: "save")
            debugLogHouseholdAssignment(entityName: "LLChild", object: child, household: scopedHousehold, context: context)
            #endif

            dismiss()
        } catch {
            context.rollback()
            print("Save child failed:", error)
        }
    }

    private func delete() {
        guard canWrite else { return }
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
