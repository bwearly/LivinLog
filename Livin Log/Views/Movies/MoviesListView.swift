//
//  MoviesListView.swift
//  Keeply
//

import SwiftUI
import CoreData

struct MoviesListView: View {
    @Environment(\.managedObjectContext) private var context

    let household: Household
    let member: HouseholdMember?

    @FetchRequest private var movies: FetchedResults<Movie>

    @State private var showingAdd = false
    @State private var didBackfill = false

    // ✅ Search
    @State private var searchText = ""

    // ✅ Filters
    @State private var mpaaFilter: String = "All"
    @State private var selectedGenres: Set<String> = []
    @State private var showGenrePicker = false

    // Slept-through filter (by member)
    @State private var sleptOnly: Bool = false
    @State private var sleptMemberID: NSManagedObjectID? = nil

    // Cached aggregates (avoid per-row fetches)
    @State private var members: [HouseholdMember] = []
    @State private var ratingByMovieID: [NSManagedObjectID: RatingSummary] = [:]
    @State private var sleptMovieIDs: Set<NSManagedObjectID> = []

    // ✅ Sort
    private enum SortOption: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case oldest = "Oldest"
        case titleAZ = "Title A–Z"
        case yearNewOld = "Year (new→old)"
        case avgRatingHighLow = "Avg rating (high→low)"

        var id: String { rawValue }
    }
    @State private var sort: SortOption = .newest

    // Pickers
    private let mpaaOptions: [String] = ["All", "G", "PG", "PG-13", "R", "NC-17", "Not Rated", "—"]
    private let allGenres: [String] = [
        "Action","Adventure","Animation","Comedy","Crime","Documentary","Drama","Family",
        "Fantasy","History","Horror","Music","Mystery","Romance","Sci-Fi","Thriller","War","Western"
    ]

    init(household: Household, member: HouseholdMember?) {
        self.household = household
        self.member = member

        let sort = [NSSortDescriptor(keyPath: \Movie.createdAt, ascending: false)]

        // Ensure household has stable id
        if household.id == nil {
            household.id = UUID()
            try? household.managedObjectContext?.save()
        }

        _movies = FetchRequest<Movie>(
            sortDescriptors: sort,
            predicate: NSPredicate(format: "householdID == %@", household.id! as CVarArg),
            animation: .default
        )
    }

    // MARK: - Derived list

    private var filteredMovies: [Movie] {
        var list = Array(movies)

        // Search (title + genre + year + mpaa)
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter { m in
                let title = (m.title ?? "").lowercased()
                let genre = (m.genre ?? "").lowercased()
                let mpaa = (m.mpaaRating ?? "").lowercased()
                let year = m.year == 0 ? "" : String(m.year)
                return title.contains(q) || genre.contains(q) || mpaa.contains(q) || year.contains(q)
            }
        }

        // MPAA filter
        if mpaaFilter != "All" {
            list = list.filter { m in
                let v = (m.mpaaRating ?? "")
                if mpaaFilter == "—" { return v.isEmpty }
                return v == mpaaFilter
            }
        }

        // Genres filter (movie must match at least one selected genre)
        if !selectedGenres.isEmpty {
            list = list.filter { m in
                let movieGenres = Set(
                    (m.genre ?? "")
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
                return !movieGenres.intersection(selectedGenres).isEmpty
            }
        }

        // Slept only (by member)
        if sleptOnly {
            list = list.filter { sleptMovieIDs.contains($0.objectID) }
        }

        // Sort
        switch sort {
        case .newest:
            list.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .oldest:
            list.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        case .titleAZ:
            list.sort { ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending }
        case .yearNewOld:
            list.sort { $0.year > $1.year }
        case .avgRatingHighLow:
            list.sort { avgRatingValue(for: $0) > avgRatingValue(for: $1) }
        }

        return list
    }

    // MARK: - UI

    var body: some View {
        List {
            if filteredMovies.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No movies yet" : "No results",
                    systemImage: "film"
                )
            } else {
                ForEach(filteredMovies) { movie in
                    NavigationLink {
                        MovieDetailView(movie: movie, household: household, member: member)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            PosterThumb(movie: movie)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(movie.title ?? "Untitled")
                                        .font(.headline)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(movie.mpaaRating ?? "")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 8) {
                                    Text(movie.year == 0 ? "—" : String(movie.year))
                                    Text("•")
                                    Text((movie.genre ?? "").isEmpty ? "—" : (movie.genre ?? ""))
                                        .lineLimit(1)
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                                // ✅ Avg household rating row (cached)
                                if let avgText = avgHouseholdRatingText(for: movie) {
                                    Text(avgText)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                if sleptOnly, sleptMovieIDs.contains(movie.objectID) {
                                    Text("😴 Slept through")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .onDelete(perform: deleteMoviesFromFiltered)
            }
        }
        .navigationTitle("Movies")
        .searchable(text: $searchText, prompt: "Search title, genre, year…")
        .navigationDestination(isPresented: $showGenrePicker) {
            GenrePickerView(title: "Select Genres", allGenres: allGenres, selected: $selectedGenres)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingAdd = true } label: {
                    Label("Add Movie", systemImage: "plus")
                }
            }

            // ✅ Filters / sort menu
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    // Sort
                    Picker("Sort", selection: $sort) {
                        ForEach(SortOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }

                    Divider()

                    // MPAA
                    Picker("MPAA", selection: $mpaaFilter) {
                        ForEach(mpaaOptions, id: \.self) { Text($0).tag($0) }
                    }

                    // Genres
                    Button {
                        showGenrePicker = true
                    } label: {
                        HStack {
                            Text("Genres")
                            Spacer()
                            if selectedGenres.isEmpty {
                                Text("All").foregroundStyle(.secondary)
                            } else {
                                Text("\(selectedGenres.count) selected").foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    // Slept filter (by member)
                    if !members.isEmpty {
                        Picker("Slept member", selection: $sleptMemberID) {
                            Text("None").tag(Optional<NSManagedObjectID>.none)
                            ForEach(members) { m in
                                Text(m.displayName ?? "Member").tag(Optional(m.objectID))
                            }
                        }

                        Toggle("Slept only", isOn: $sleptOnly)
                            .disabled(sleptMemberID == nil)
                    }

                    Divider()

                    Button("Clear filters") {
                        mpaaFilter = "All"
                        selectedGenres.removeAll()
                        sleptOnly = false
                        sleptMemberID = nil
                        sort = .newest
                    }
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                AddMovieView(household: household, member: member)
            }
        }
        .task {
            guard !didBackfill else { return }
            didBackfill = true
            await backfillHouseholdIDAndPostersIfNeeded()
            reloadMembers()
            await reloadAggregates()

            // default slept member to current member if available
            if sleptMemberID == nil, let member {
                sleptMemberID = member.objectID
            }
        }
        .onChange(of: sleptMemberID) { _, _ in
            Task { await reloadSleptAggregates() }
        }
        .onChange(of: sleptOnly) { _, _ in
            Task { await reloadSleptAggregates() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)) { _ in
            Task { await reloadAggregates() }
        }
    }

    // MARK: - Backfill (unchanged)

    private func backfillHouseholdIDAndPostersIfNeeded() async {
        if household.id == nil {
            await MainActor.run {
                household.id = UUID()
                try? context.save()
            }
        }
        guard let hid = household.id else { return }

        await MainActor.run {
            let req = NSFetchRequest<Movie>(entityName: "Movie")
            req.predicate = NSPredicate(format: "household == %@ AND householdID == nil", household)

            if let legacy = try? context.fetch(req), !legacy.isEmpty {
                for m in legacy { m.householdID = hid }
                try? context.save()
            }
        }

        let missing: [Movie] = await MainActor.run {
            let req = NSFetchRequest<Movie>(entityName: "Movie")
            req.predicate = NSPredicate(format: "householdID == %@ AND (posterURL == nil OR posterURL == '')", hid as CVarArg)
            return (try? context.fetch(req)) ?? []
        }

        guard !missing.isEmpty else { return }

        var updates: [(NSManagedObjectID, String)] = []

        for m in missing {
            let fetched = await OMDbPosterService.posterURL(title: m.title, year: m.year)
            guard let fetched else { continue }
            updates.append((m.objectID, fetched.absoluteString))
        }

        guard !updates.isEmpty else { return }

        await MainActor.run {
            for (oid, urlString) in updates {
                if let obj = try? context.existingObject(with: oid) as? Movie {
                    obj.posterURL = urlString
                }
            }
            try? context.save()
        }
    }

    // MARK: - Helpers (members + aggregates)

    private func reloadMembers() {
        let req = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        if let hid = household.id {
            req.predicate = NSPredicate(format: "household.id == %@", hid as CVarArg)
        } else {
            req.predicate = NSPredicate(format: "household == %@", household)
        }
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        members = (try? context.fetch(req)) ?? []
    }

    private func reloadAggregates() async {
        await reloadRatingAggregates()
        await reloadSleptAggregates()
    }

    private func reloadRatingAggregates() async {
        await context.perform {
            let req = NSFetchRequest<NSDictionary>(entityName: "MovieFeedback")
            req.predicate = NSPredicate(format: "household == %@ AND rating > 0", household)
            req.resultType = .dictionaryResultType

            let avgExpr = NSExpressionDescription()
            avgExpr.name = "avgRating"
            avgExpr.expression = NSExpression(forFunction: "average:", arguments: [NSExpression(forKeyPath: "rating")])
            avgExpr.expressionResultType = .doubleAttributeType

            let countExpr = NSExpressionDescription()
            countExpr.name = "countRating"
            countExpr.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "rating")])
            countExpr.expressionResultType = .integer64AttributeType

            req.propertiesToFetch = ["movie", avgExpr, countExpr]
            req.propertiesToGroupBy = ["movie"]

            let results = (try? context.fetch(req)) ?? []
            var mapped: [NSManagedObjectID: RatingSummary] = [:]

            for dict in results {
                guard let movieID = dict["movie"] as? NSManagedObjectID else { continue }
                let avg = (dict["avgRating"] as? Double) ?? 0
                let count = Int((dict["countRating"] as? Int64) ?? 0)
                mapped[movieID] = RatingSummary(avg: avg, count: count)
            }

            ratingByMovieID = mapped
            print("ℹ️ Reloaded rating aggregates:", mapped.count)
        }
    }

    private func reloadSleptAggregates() async {
        guard sleptOnly, let sleptMemberID,
              let selectedMember = members.first(where: { $0.objectID == sleptMemberID }) else {
            await MainActor.run { sleptMovieIDs = [] }
            return
        }

        await context.perform {
            let req = NSFetchRequest<NSDictionary>(entityName: "MovieFeedback")
            req.predicate = NSPredicate(format: "household == %@ AND member == %@ AND slept == YES", household, selectedMember)
            req.resultType = .dictionaryResultType
            req.propertiesToFetch = ["movie"]
            req.propertiesToGroupBy = ["movie"]

            let results = (try? context.fetch(req)) ?? []
            let ids = results.compactMap { $0["movie"] as? NSManagedObjectID }
            sleptMovieIDs = Set(ids)
        }
    }

    private func avgHouseholdRatingText(for movie: Movie) -> String? {
        guard let summary = ratingByMovieID[movie.objectID], summary.count > 0 else { return nil }
        return "Avg \(String(format: "%.1f", summary.avg))/10 (\(summary.count))"
    }

    private func avgRatingValue(for movie: Movie) -> Double {
        ratingByMovieID[movie.objectID]?.avg ?? 0
    }

    // MARK: - Delete

    private func deleteMoviesFromFiltered(offsets: IndexSet) {
        let toDelete = offsets.map { filteredMovies[$0] }
        toDelete.forEach(context.delete)
        save()
    }

    private func save() {
        do { try context.save() }
        catch { print("Save failed:", error) }
    }
}

// MARK: - Rating summary

private struct RatingSummary {
    let avg: Double
    let count: Int
}

// MARK: - Poster Thumbnail

private struct PosterThumb: View {
    @Environment(\.managedObjectContext) private var context

    let movie: Movie
    @State private var url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))

            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty: ProgressView()
                    case .success(let image): image.resizable().scaledToFill()
                    default:
                        Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 54, height: 80)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 0.5))
        .task(id: movie.objectID) {
            if let s = movie.posterURL, !s.isEmpty, let saved = URL(string: s) {
                url = saved
                return
            }

            let fetched = await OMDbPosterService.posterURL(title: movie.title, year: movie.year)
            url = fetched

            if let fetched {
                await MainActor.run {
                    movie.posterURL = fetched.absoluteString
                    try? context.save()
                }
            }
        }
    }
}
