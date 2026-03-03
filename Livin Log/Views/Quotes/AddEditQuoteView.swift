import SwiftUI
import CoreData

struct AddEditQuoteView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    let household: Household
    let editingQuote: LLQuote?

    @FetchRequest private var children: FetchedResults<LLChild>

    @State private var quoteText = ""
    @State private var speakerName = ""
    @State private var saidAt = Date()
    @State private var contextText = ""
    @State private var selectedChildID: NSManagedObjectID?
    @State private var showingDeleteAlert = false

    private let persistentContainer = PersistenceController.shared.container

    init(household: Household, editingQuote: LLQuote? = nil) {
        self.household = household
        self.editingQuote = editingQuote

        _children = FetchRequest<LLChild>(
            sortDescriptors: [NSSortDescriptor(keyPath: \LLChild.name, ascending: true)],
            predicate: NSPredicate(format: "household == %@", household),
            animation: .default
        )
    }

    private var isEditing: Bool { editingQuote != nil }

    var body: some View {
        Form {
            Section("Quote") {
                TextEditor(text: $quoteText)
                    .frame(minHeight: 110)
                    .overlay(alignment: .topLeading) {
                        if quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Quote text")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                    }

                TextField("Speaker name", text: $speakerName)
                DatePicker("Said at", selection: $saidAt, displayedComponents: [.date, .hourAndMinute])
            }

            Section("Context") {
                TextEditor(text: $contextText)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if contextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Optional context")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                    }
            }

            Section("Child") {
                Picker("Linked Child", selection: $selectedChildID) {
                    Text("None").tag(Optional<NSManagedObjectID>.none)
                    ForEach(children, id: \.objectID) { child in
                        Text(child.nameValue).tag(Optional(child.objectID))
                    }
                }

                if let selectedChild {
                    Text("Age at quote: \(formattedAge(months: ageInMonths(birthday: selectedChild.birthdayValue, at: saidAt)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isEditing {
                Section {
                    Button("Delete Quote", role: .destructive) {
                        showingDeleteAlert = true
                    }
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Quote" : "Add Quote")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveQuote() }
                    .disabled(!canSave)
            }
        }
        .alert("Delete this quote?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                deleteQuote()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
        .onAppear(perform: seed)
    }

    private var canSave: Bool {
        !quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedChild: LLChild? {
        guard let selectedChildID else { return nil }
        return children.first { $0.objectID == selectedChildID }
    }

    private func seed() {
        guard let editingQuote else { return }
        quoteText = editingQuote.textValue
        speakerName = editingQuote.speakerNameValue
        saidAt = editingQuote.saidAt ?? .now
        contextText = editingQuote.contextTextValue
        selectedChildID = editingQuote.child?.objectID
    }

    private func saveQuote() {
        let now = Date()

        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
            print("❌ Could not resolve household in context for quote save")
            return
        }

        let quote: LLQuote
        if let editingQuote,
           let existing = (try? context.existingObject(with: editingQuote.objectID)) as? LLQuote {
            quote = existing
        } else {
            quote = LLQuote(context: context)
        }

        if let store = scopedHousehold.objectID.persistentStore {
            context.assign(quote, to: store)
        }

        if quote.id == nil { quote.id = UUID() }
        if quote.createdAt == nil { quote.createdAt = now }

        quote.household = scopedHousehold
        quote.updatedAt = now
        quote.textValue = quoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        quote.speakerNameValue = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        quote.saidAt = saidAt

        let trimmedContext = contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        quote.contextTextValue = trimmedContext
        quote.contextText = trimmedContext.isEmpty ? nil : trimmedContext

        if let selectedChildID,
           let childInContext = (try? context.existingObject(with: selectedChildID)) as? LLChild {
            quote.child = childInContext
            quote.ageInMonthsAtSaidAt = ageInMonths(birthday: childInContext.birthdayValue, at: saidAt)
        } else {
            quote.child = nil
            quote.ageInMonthsAtSaidAt = 0
        }

        do {
            try context.save()
            includeInHouseholdShare(
                persistentContainer: persistentContainer,
                household: scopedHousehold,
                objects: [quote],
                label: "LLQuote"
            )
#if DEBUG
            debugPrintHouseholdDiagnostics(household: scopedHousehold, context: context, reason: "save")
            debugLogHouseholdAssignment(entityName: "LLQuote", object: quote, household: scopedHousehold, context: context)
#endif
            dismiss()
        } catch {
            context.rollback()
            print("Save quote failed:", error)
        }
    }

    private func deleteQuote() {
        guard let editingQuote else { return }
        context.delete(editingQuote)

        do {
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            print("Delete quote failed:", error)
        }
    }

    private func formattedAge(months: Int32) -> String {
        "\(Int(months) / 12)y \(Int(months) % 12)m"
    }
}
