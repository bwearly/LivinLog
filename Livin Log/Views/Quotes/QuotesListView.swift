import SwiftUI
import CoreData

struct QuotesListView: View {
    let household: Household

    @FetchRequest private var quotes: FetchedResults<LLQuote>
    @FetchRequest private var children: FetchedResults<LLChild>

    @State private var searchText = ""
    @State private var filters = QuoteFilterState()

    @State private var showingAddQuote = false
    @State private var editingQuote: LLQuote?
    @State private var showingFilters = false
    @State private var showingChildrenManager = false

    init(household: Household) {
        self.household = household

        _quotes = FetchRequest<LLQuote>(
            sortDescriptors: [
                NSSortDescriptor(keyPath: \LLQuote.saidAt, ascending: false),
                NSSortDescriptor(keyPath: \LLQuote.createdAt, ascending: false)
            ],
            predicate: NSPredicate(format: "household == %@", household),
            animation: .default
        )

        _children = FetchRequest<LLChild>(
            sortDescriptors: [NSSortDescriptor(keyPath: \LLChild.name, ascending: true)],
            predicate: NSPredicate(format: "household == %@", household),
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

        if let selectedChildID = filters.selectedChildID {
            result = result.filter { $0.child?.objectID == selectedChildID }

            if let ageRange = filters.selectedAgeRange {
                result = result.filter { ageRange.contains(Int($0.ageInMonthsAtSaidAt)) }
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
                    ContentUnavailableView {
                        Label("No quotes yet", systemImage: "quote.bubble")
                    } description: {
                        Text("Capture your household sayings and memories.")
                    } actions: {
                        Button("Add Quote") {
                            showingAddQuote = true
                        }
                    }
                } else {
                    ContentUnavailableView("No results", systemImage: "magnifyingglass")
                }
            } else {
                ForEach(filteredQuotes, id: \.objectID) { quote in
                    NavigationLink {
                        QuoteDetailView(quote: quote, household: household)
                    } label: {
                        QuoteRowView(quote: quote)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Edit") {
                            editingQuote = quote
                        }
                    }
                }
            }
        }
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

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showingChildrenManager = true
                } label: {
                    Image(systemName: "figure.and.child.holdinghands")
                }
                .accessibilityLabel("Manage Children")

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
                    children: Array(children),
                    recentSpeakers: recentSpeakers,
                    allYears: Set(quotes.compactMap { quote in
                        guard let saidAt = quote.saidAt else { return nil }
                        return Calendar.current.component(.year, from: saidAt)
                    })
                ) {
                    showingFilters = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showingChildrenManager = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingChildrenManager) {
            NavigationStack {
                ChildrenManagerView(household: household)
            }
        }
    }
}

private struct QuoteRowView: View {
    let quote: LLQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(quote.textValue)")
                .font(.body)
                .lineLimit(3)

            HStack(spacing: 8) {
                Text("— \(quote.speakerNameValue)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let ageText = quote.childAgeLabel {
                    Text(ageText)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.thinMaterial))
                }
            }

            Text((quote.saidAt ?? .now).formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct QuoteFilterState {
    var speakerQuery = ""
    var selectedRecentSpeaker: String?
    var selectedChildID: NSManagedObjectID?
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

    var childAgeLabel: String? {
        guard ageInMonthsAtSaidAt > 0 else { return nil }
        return "Age \(Int(ageInMonthsAtSaidAt) / 12)y \(Int(ageInMonthsAtSaidAt) % 12)m"
    }

    var shareText: String {
        var value = "\"\(textValue)\" — \(speakerNameValue)"
        if let saidAt {
            value += " (\(saidAt.formatted(date: .abbreviated, time: .omitted)))"
        }
        if let childAgeLabel {
            value += " • \(childAgeLabel)"
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
