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
            heroSection
            emptyStateSection
            childrenSection
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [Color.pink.opacity(0.10), Color.orange.opacity(0.06), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .navigationTitle("Children")
        .navigationBarItems(trailing: addButton)
        .sheet(isPresented: $showingAdd, content: addSheet)
        .sheet(item: $editingChild) { child in
            editSheet(for: child)
        }
    }

    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.pink.opacity(0.35), Color.orange.opacity(0.25)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 48, height: 48)

                        Image(systemName: "figure.and.child.holdinghands")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Family Profiles")
                            .font(.headline)

                        Text("Add children so quotes, milestones, and memories can stay connected to the right person.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Label("\(children.count) \(children.count == 1 ? "child" : "children")", systemImage: "person.2.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.pink.opacity(0.14)))
                        .foregroundStyle(Color.pink.opacity(0.95))

                    if canWrite {
                        Label("Editable", systemImage: "pencil")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                            .foregroundStyle(Color.orange.opacity(0.95))
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10))
                )
        )
    }

    @ViewBuilder
    private var emptyStateSection: some View {
        if children.isEmpty {
            Section {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.pink.opacity(0.28), Color.orange.opacity(0.20)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 58, height: 58)

                        Image(systemName: "figure.and.child.holdinghands")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(spacing: 6) {
                        Text("No children yet")
                            .font(.headline)

                        Text("Add a child profile to make quotes and family memories feel more personal.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if canWrite {
                        Button {
                            showingAdd = true
                        } label: {
                            Label("Add Child", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.thinMaterial)
            )
        }
    }

    private var childrenSection: some View {
        Section {
            ForEach(children, id: \.objectID) { child in
                ChildRowButton(child: child) {
                    editingChild = child
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .onDelete(perform: canWrite ? { offsets in
                deleteChildren(at: offsets)
            } : nil)
        } header: {
            if children.isEmpty == false {
                Label("Household Members", systemImage: "person.2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.pink.opacity(0.9))
            }
        }
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
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.pink.opacity(0.30), Color.orange.opacity(0.22)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)

                    Text(initials)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(child.nameValue)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Label(child.birthdayValue.formatted(date: .abbreviated, time: .omitted), systemImage: "gift.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.pink.opacity(0.16), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var initials: String {
        let parts = child.nameValue
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        let value = String(parts).uppercased()
        return value.isEmpty ? "?" : value
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
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label(isEditing ? "Update this profile" : "Create a child profile", systemImage: "figure.and.child.holdinghands")
                        .font(.headline)

                    Text("Child profiles help keep quotes, birthdays, and memories organized by person.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.pink.opacity(0.16), Color.orange.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )

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
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [Color.pink.opacity(0.10), Color.orange.opacity(0.05), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
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
