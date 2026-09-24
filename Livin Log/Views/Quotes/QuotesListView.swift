import SwiftUI
import CoreData

struct QuotesListView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState

    let household: Household

    @FetchRequest private var quotes: FetchedResults<LLQuote>
    @FetchRequest private var members: FetchedResults<HouseholdMember>

    @State private var searchText = ""
    @State private var filters = QuoteFilterState()

    @State private var showingAddQuote = false
    @State private var editingQuote: LLQuote?
    @State private var showingFilters = false
    @State private var didRepairHouseholdLinks = false
    @State private var repairError: String?

    private var canWrite: Bool {
        appState.isCurrentMemberAuthorized()
    }

    init(household: Household) {
        self.household = household

        _quotes = FetchRequest<LLQuote>(
            sortDescriptors: [
                NSSortDescriptor(keyPath: \LLQuote.saidAt, ascending: false),
                NSSortDescriptor(keyPath: \LLQuote.createdAt, ascending: false)
            ],
            predicate: householdScopedPredicate(household, idKey: "householdId"),
            animation: .default
        )

        _members = FetchRequest<HouseholdMember>(
            sortDescriptors: [NSSortDescriptor(key: "displayName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))],
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                householdScopedPredicate(household, idKey: "householdId"),
                NSPredicate(format: "isActive == YES")
            ]),
            animation: .default
        )
    }

    private var filteredQuotes: [LLQuote] {
        var result = Array(quotes)

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { quote in
                quote.textValue.lowercased().contains(query)
                || quote.speakerNameValue.lowercased().contains(query)
                || quote.contextTextValue.lowercased().contains(query)
            }
        }

        if !filters.speakerQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let speakerQuery = filters.speakerQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            result = result.filter { $0.speakerNameValue.lowercased().contains(speakerQuery) }
        }

        if let selectedSpeaker = filters.selectedRecentSpeaker,
           !selectedSpeaker.isEmpty {
            result = result.filter { $0.speakerNameValue.caseInsensitiveCompare(selectedSpeaker) == .orderedSame }
        }

        if let selectedMemberID = filters.selectedMemberID {
            result = result.filter { $0.member?.objectID == selectedMemberID }

            if let ageRange = filters.selectedAgeRange {
                // No computable age (no member, or no birthday) never matches a range.
                result = result.filter { quote in quote.speakerAgeInMonths.map(ageRange.contains) ?? false }
            }
        }

        if let selectedYear = filters.selectedYear {
            let start = Calendar.current.date(from: DateComponents(year: selectedYear, month: 1, day: 1)) ?? .distantPast
            let end = Calendar.current.date(byAdding: DateComponents(year: 1, day: -1), to: start) ?? .distantFuture
            result = result.filter {
                guard let saidAt = $0.saidAt else { return false }
                return saidAt >= start && saidAt <= end
            }
        }

        switch filters.sortOption {
        case .newest:
            result.sort { ($0.saidAt ?? .distantPast) > ($1.saidAt ?? .distantPast) }
        case .oldest:
            result.sort { ($0.saidAt ?? .distantPast) < ($1.saidAt ?? .distantPast) }
        case .speakerAZ:
            result.sort {
                let lhs = $0.speakerNameValue.localizedLowercase
                let rhs = $1.speakerNameValue.localizedLowercase
                if lhs == rhs {
                    return ($0.saidAt ?? .distantPast) > ($1.saidAt ?? .distantPast)
                }
                return lhs < rhs
            }
        }

        return result
    }

    private var recentSpeakers: [String] {
        let ordered = Array(quotes)
            .sorted { ($0.saidAt ?? .distantPast) > ($1.saidAt ?? .distantPast) }
            .map { $0.speakerNameValue }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var values: [String] = []
        for speaker in ordered {
            let key = speaker.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            values.append(speaker)
            if values.count >= 8 { break }
        }
        return values
    }

    var body: some View {
        List {
            if filteredQuotes.isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SharedViews.SoftEmptyState(
                        title: "No quotes yet",
                        systemImage: "quote.bubble.fill",
                        style: .quotes,
                        description: "Capture your household sayings and memories."
                    )
                    .listRowBackground(Color.clear)

                    Button("Add Quote") {
                        showingAddQuote = true
                    }
                    .foregroundStyle(AppCategoryStyle.quotes.accent)
                    .listRowBackground(Color.clear)
                } else {
                    SharedViews.SoftEmptyState(
                        title: "No results",
                        systemImage: "magnifyingglass",
                        style: .quotes,
                        description: "Try a different speaker, quote, or context."
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(filteredQuotes, id: \.objectID) { quote in
                    NavigationLink {
                        QuoteDetailView(quote: quote, household: household)
                    } label: {
                        QuoteRowView(quote: quote)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Edit") {
                            editingQuote = quote
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Quotes")
        .searchable(text: $searchText, prompt: "Search text, speaker, context")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showingFilters = true
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
            }

            // Phase 4a: the "Manage Children" button is gone -- ChildrenManagerView is retired;
            // birthdays now live on household members (Settings).
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showingAddQuote = true
                } label: {
                    Label("Add Quote", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddQuote) {
            NavigationStack {
                AddEditQuoteView(household: household)
            }
        }
        .sheet(item: $editingQuote) { quote in
            NavigationStack {
                AddEditQuoteView(household: household, editingQuote: quote)
            }
        }
        .sheet(isPresented: $showingFilters) {
            NavigationStack {
                QuoteFiltersSheet(
                    filters: $filters,
                    members: Array(members),
                    recentSpeakers: recentSpeakers,
                    allYears: Set(quotes.compactMap { quote in
                        guard let saidAt = quote.saidAt else { return nil }
                        return Calendar.current.component(.year, from: saidAt)
                    })
                )
            }
        }
        .task {
            guard !didRepairHouseholdLinks else { return }
            didRepairHouseholdLinks = true
            logQuoteFetchDiagnostics(reason: "QuotesListView.task")
            if canWrite {
                repairQuoteHouseholdLinksIfNeeded()
            }
        }
        .alert("Could Not Update Quotes", isPresented: Binding(get: { repairError != nil }, set: { if !$0 { repairError = nil } })) {
            Button("OK", role: .cancel) { repairError = nil }
        } message: {
            Text(repairError ?? "Unknown error")
        }
    }

    private func repairQuoteHouseholdLinksIfNeeded() {
        guard canWrite else { return }
        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
            repairError = "Could not resolve the active household."
            return
        }

        var didRepairHouseholdLinks = false

        if scopedHousehold.id == nil {
            scopedHousehold.id = UUID()
            didRepairHouseholdLinks = true
        }

        guard let householdID = scopedHousehold.id else { return }

        let missingHouseholdIDRequest = NSFetchRequest<LLQuote>(entityName: "LLQuote")
        missingHouseholdIDRequest.predicate = NSPredicate(format: "household == %@ AND householdId == nil", scopedHousehold)
        missingHouseholdIDRequest.includesPendingChanges = true

        let orphanedByHouseholdIDRequest = NSFetchRequest<LLQuote>(entityName: "LLQuote")
        orphanedByHouseholdIDRequest.predicate = NSPredicate(format: "household == nil AND householdId == %@", householdID as NSUUID)
        orphanedByHouseholdIDRequest.includesPendingChanges = true

        do {
            let missingHouseholdID = try context.fetch(missingHouseholdIDRequest)
            let orphanedByHouseholdID = try context.fetch(orphanedByHouseholdIDRequest)

            for quote in missingHouseholdID {
                do {
                    try context.validateSamePersistentStore([("quote", quote), ("household", scopedHousehold), ("child", quote.child)])
                } catch {
                    print("⚠️ [QuoteRepair] skipped cross-store quote (preflight) quote=\(quote.textValue.prefix(32)) householdID=\(householdID.uuidString)")
                    continue
                }
                quote.setValue(householdID, forKey: "householdId")
                didRepairHouseholdLinks = true
                try context.validateSamePersistentStore([("quote", quote), ("household", scopedHousehold), ("child", quote.child)])
                print("💬 [QuoteRepair] backfilled householdId quote=\(quote.textValue.prefix(32)) householdID=\(householdID.uuidString)")
            }

            for quote in orphanedByHouseholdID {
                guard quote.objectID.persistentStore === scopedHousehold.objectID.persistentStore else {
                    print("⚠️ [QuoteRepair] skipped cross-store orphan quote=\(quote.textValue.prefix(32)) householdID=\(householdID.uuidString)")
                    continue
                }
                do {
                    try context.validateSamePersistentStore([("quote", quote), ("household", scopedHousehold), ("child", quote.child)])
                } catch {
                    print("⚠️ [QuoteRepair] skipped cross-store orphan (child) quote=\(quote.textValue.prefix(32)) householdID=\(householdID.uuidString)")
                    continue
                }
                quote.household = scopedHousehold
                didRepairHouseholdLinks = true
                try context.validateSamePersistentStore([("quote", quote), ("household", scopedHousehold), ("child", quote.child)])
                print("💬 [QuoteRepair] relinked quote=\(quote.textValue.prefix(32)) householdID=\(householdID.uuidString)")
            }

            if didRepairHouseholdLinks {
                context.debugLogStoreSafeSave(entityName: "LLQuote.householdRepair", household: scopedHousehold, member: appState.member, objects: [("household", scopedHousehold)])
                try context.save()
            }
        } catch {
            context.rollback()
            repairError = error.localizedDescription
            print("❌ [QuoteRepair] household link save blocked: \(error)")
        }
    }

    private func logQuoteFetchDiagnostics(reason: String) {
#if DEBUG
        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
            print("💬 [QuoteFetch] reason=\(reason) active household could not be resolved")
            return
        }
        let request = NSFetchRequest<LLQuote>(entityName: "LLQuote")
        request.predicate = householdScopedPredicate(scopedHousehold, idKey: "householdId")
        request.includesPendingChanges = true
        let fetched = (try? context.fetch(request)) ?? []
        print("💬 [QuoteFetch] reason=\(reason) household=\(scopedHousehold.name ?? "<unnamed>") householdID=\(scopedHousehold.id?.uuidString ?? "<nil>") count=\(fetched.count)")
#endif
    }
}

private struct QuoteRowView: View {
    let quote: LLQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 7) {
                SharedViews.AccentIconBadge(systemImage: "quote.bubble.fill", style: .quotes)

                Text("\(quote.textValue)")
                    .font(.body)
                    .lineLimit(3)

                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Text("— \(quote.speakerNameValue)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let ageText = quote.speakerAgeLabel {
                    SharedViews.AccentPill(ageText, systemImage: "clock", style: .quotes)
                }

                Spacer(minLength: 0)
            }

            Text((quote.saidAt ?? .now).formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .subtleCategoryRowCard(style: .quotes, horizontalPadding: 9, verticalPadding: 6)
    }
}

struct QuoteFilterState {
    var speakerQuery = ""
    var selectedRecentSpeaker: String?
    var selectedMemberID: NSManagedObjectID?
    var selectedAgeRange: QuoteAgeRange?
    var selectedYear: Int?
    var sortOption: QuoteSortOption = .newest
}

enum QuoteSortOption: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"
    case speakerAZ = "Speaker A–Z"

    var id: String { rawValue }
}

enum QuoteAgeRange: String, CaseIterable, Identifiable {
    case months0to12 = "0–12 months"
    case years1to2 = "1–2 years"
    case years2to3 = "2–3 years"
    case years3to5 = "3–5 years"

    var id: String { rawValue }

    func contains(_ months: Int) -> Bool {
        switch self {
        case .months0to12:
            return (0...12).contains(months)
        case .years1to2:
            return (12...24).contains(months)
        case .years2to3:
            return (24...36).contains(months)
        case .years3to5:
            return (36...60).contains(months)
        }
    }
}

extension LLQuote {
    var textValue: String {
        get { (value(forKey: "text") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (value(forKey: "text") as? String ?? "") : "Untitled quote" }
        set { setValue(newValue, forKey: "text") }
    }

    var speakerNameValue: String {
        get { (value(forKey: "speakerName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (value(forKey: "speakerName") as? String ?? "") : "Unknown" }
        set { setValue(newValue, forKey: "speakerName") }
    }

    var contextTextValue: String {
        get { (value(forKey: "contextText") as? String) ?? "" }
        set { setValue(newValue, forKey: "contextText") }
    }

    /// Phase 4a: the speaker's age when the quote was said, computed at read time. This is the
    /// one source for the row, detail view, Quote of the Day, share text and the age-range
    /// filter. nil unless the quote has a member who has a birthday; nil shows no age and never
    /// matches an age-range filter. The stored `ageInMonthsAtSaidAt` attribute is no longer read
    /// or written (disabled, not deleted -- it stays in the model, unused and unsynced).
    var speakerAgeInMonths: Int? {
        quoteSpeakerAgeInMonths(birthday: member?.value(forKey: "birthday") as? Date, saidAt: saidAt)
    }

    var speakerAgeLabel: String? {
        speakerAgeInMonths.map { formattedQuoteAge(months: $0) }
    }

    var shareText: String {
        var value = "\"\(textValue)\" — \(speakerNameValue)"
        if let saidAt {
            value += " (\(saidAt.formatted(date: .abbreviated, time: .omitted)))"
        }
        if let speakerAgeLabel {
            value += " • \(speakerAgeLabel)"
        }
        if !contextTextValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value += "\nContext: \(contextTextValue)"
        }
        return value
    }
}

extension LLChild {
    var nameValue: String {
        get { (value(forKey: "name") as? String) ?? "Unnamed Child" }
        set { setValue(newValue, forKey: "name") }
    }

    var birthdayValue: Date {
        get { (value(forKey: "birthday") as? Date) ?? .now }
        set { setValue(newValue, forKey: "birthday") }
    }
}

/// The single quote-age calculation (Phase 4a): whole months from `birthday` to `saidAt`, or
/// nil when either is missing or the quote predates the birthday. Used by
/// `LLQuote.speakerAgeInMonths` and by AddEditQuoteView's live preview of an unsaved quote.
func quoteSpeakerAgeInMonths(birthday: Date?, saidAt: Date?) -> Int? {
    guard let birthday, let saidAt, saidAt >= birthday else { return nil }
    return Int(ageInMonths(birthday: birthday, at: saidAt))
}

func formattedQuoteAge(months: Int) -> String {
    "Age \(months / 12)y \(months % 12)m"
}

func ageInMonths(birthday: Date, at referenceDate: Date, calendar: Calendar = .current) -> Int32 {
    if referenceDate < birthday { return 0 }

    let b = calendar.dateComponents([.year, .month, .day], from: birthday)
    let r = calendar.dateComponents([.year, .month, .day], from: referenceDate)

    let yearDiff = (r.year ?? 0) - (b.year ?? 0)
    let monthDiff = (r.month ?? 0) - (b.month ?? 0)
    var months = yearDiff * 12 + monthDiff

    if (r.day ?? 0) < (b.day ?? 0) {
        months -= 1
    }

    return Int32(max(0, months))
}
