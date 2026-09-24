import SwiftUI
import CoreData

struct AddEditQuoteView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let household: Household
    let editingQuote: LLQuote?

    /// Phase 4a: the speaker is a household member (LLChild is retired). "Other" keeps the
    /// free-text speaker for someone outside the household.
    enum SpeakerChoice: Hashable {
        case unset
        case member(NSManagedObjectID)
        case other
    }

    @FetchRequest private var members: FetchedResults<HouseholdMember>

    @State private var quoteText = ""
    @State private var speakerName = ""
    @State private var speakerChoice: SpeakerChoice = .unset
    @State private var saidAt = Date()
    @State private var contextText = ""
    @State private var showingDeleteAlert = false
    @State private var saveError: String?

    private let persistentContainer = PersistenceController.shared.container
    private var canWrite: Bool {
        appState.isCurrentMemberAuthorized()
    }

    init(household: Household, editingQuote: LLQuote? = nil) {
        self.household = household
        self.editingQuote = editingQuote

        _members = FetchRequest<HouseholdMember>(
            sortDescriptors: [NSSortDescriptor(key: "displayName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))],
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                householdScopedPredicate(household, idKey: "householdId"),
                NSPredicate(format: "isActive == YES")
            ]),
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

                Picker("Speaker", selection: $speakerChoice) {
                    Text("Choose…").tag(SpeakerChoice.unset)
                    ForEach(pickerMembers, id: \.objectID) { member in
                        Text(member.displayName ?? "Unnamed").tag(SpeakerChoice.member(member.objectID))
                    }
                    Text("Someone else").tag(SpeakerChoice.other)
                }

                if speakerChoice == .other {
                    TextField("Speaker name", text: $speakerName)
                }

                DatePicker("Said at", selection: $saidAt, displayedComponents: [.date, .hourAndMinute])

                if let months = quoteSpeakerAgeInMonths(birthday: selectedMember?.value(forKey: "birthday") as? Date, saidAt: saidAt) {
                    Text(formattedQuoteAge(months: months))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            if isEditing {
                Section {
                    Button("Delete Quote", role: .destructive) {
                        showingDeleteAlert = true
                    }
                    .disabled(!canWrite)
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
                    .disabled(!canSave || !canWrite)
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
        .alert("Could Not Save Quote", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "The quote could not be saved.")
        }
        .onAppear(perform: seed)
    }

    private var canSave: Bool {
        guard !quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch speakerChoice {
        case .unset: return false
        case .member: return selectedMember != nil
        case .other: return !speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Active members, plus the edited quote's member if they've since left the household, so
    /// an existing selection never silently disappears from the picker.
    private var pickerMembers: [HouseholdMember] {
        var result = Array(members)
        if let existing = editingQuote?.member, !result.contains(where: { $0.objectID == existing.objectID }) {
            result.append(existing)
        }
        return result
    }

    private var selectedMember: HouseholdMember? {
        guard case .member(let id) = speakerChoice else { return nil }
        return pickerMembers.first { $0.objectID == id }
    }

    private func seed() {
        guard let editingQuote else { return }
        quoteText = editingQuote.textValue
        saidAt = editingQuote.saidAt ?? .now
        contextText = editingQuote.contextTextValue
        if let member = editingQuote.member {
            speakerChoice = .member(member.objectID)
        } else {
            // Free-text speaker (including quotes from before members could be linked).
            speakerChoice = .other
            speakerName = editingQuote.speakerNameValue
        }
    }

    private func saveQuote() {
        saveError = nil
        guard canWrite else {
            saveError = "You can save quotes only from your authorized member profile."
            return
        }
        let now = Date()

        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
            saveError = "Could not resolve the active household."
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

        let store = editingQuote != nil ? storeForParent(quote) : scopedHousehold.objectID.persistentStore
        assignIfInserted(quote, to: store, in: context)
#if DEBUG
        print("🧩 [EditSave] entity=LLQuote store=\(store?.url?.lastPathComponent ?? "nil-store") objectID=\(quote.objectID.uriRepresentation().absoluteString)")
#endif

        if quote.id == nil { quote.id = UUID() }
        if quote.createdAt == nil { quote.createdAt = now }
        if scopedHousehold.id == nil { scopedHousehold.id = UUID() }

        quote.household = scopedHousehold
        quote.setValue(scopedHousehold.id, forKey: "householdId")
        quote.updatedAt = now
        quote.textValue = quoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        quote.saidAt = saidAt

        let trimmedContext = contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        quote.contextTextValue = trimmedContext
        quote.contextText = trimmedContext.isEmpty ? nil : trimmedContext

        // speakerName stays a snapshot of the speaker's name, so search, filters, sharing and
        // quotes from before members could be linked all keep working unchanged. Age is no
        // longer stored: it's computed at read time (LLQuote.speakerAgeInMonths), and
        // `ageInMonthsAtSaidAt` is left untouched (disabled, not deleted).
        switch speakerChoice {
        case .member(let memberID):
            guard let memberInContext = (try? context.existingObject(with: memberID)) as? HouseholdMember else {
                saveError = "That member no longer exists."
                context.rollback()
                return
            }
            quote.member = memberInContext
            quote.speakerNameValue = memberInContext.displayName ?? "Unknown"
        case .other, .unset:
            quote.member = nil
            quote.speakerNameValue = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // LLChild is retired (Phase 4a, clean break): drop any old child link on save.
        quote.child = nil

        do {
            let objectsToValidate: [(String, NSManagedObject?)] = [("quote", quote), ("household", scopedHousehold), ("member", quote.member)]
            let preview = String(quote.textValue.prefix(48))
            print("💬 [QuoteSave] quote=\(preview) household=\(scopedHousehold.name ?? "<unnamed>") householdID=\(scopedHousehold.id?.uuidString ?? "<nil>") member=\(appState.member?.displayName ?? "<nil>")")
            context.debugLogStoreSafeSave(entityName: "LLQuote", household: scopedHousehold, member: appState.member, objects: objectsToValidate)
            try context.validateSamePersistentStore(objectsToValidate)
            try context.save()
            print("ℹ️ LLQuote inherits household share via parent household relationship (no per-object share mutation)")
#if DEBUG
            debugPrintHouseholdDiagnostics(household: scopedHousehold, context: context, reason: "save")
            debugLogHouseholdAssignment(entityName: "LLQuote", object: quote, household: scopedHousehold, context: context)
#endif
            dismiss()
        } catch {
            context.rollback()
            saveError = "Could not save quote: \(error.localizedDescription)"
            print("Save quote failed:", error)
        }
    }

    private func deleteQuote() {
        guard canWrite else { return }
        guard let editingQuote else { return }
        do {
            try context.validateSamePersistentStore([("quote", editingQuote), ("household", editingQuote.household), ("member", editingQuote.member)])
            context.delete(editingQuote)
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            print("Delete quote failed:", error)
        }
    }
}
