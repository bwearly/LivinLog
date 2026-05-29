//
//  MoviesListView.swift
//  Livin Log
//

import SwiftUI
import CoreData

struct MoviesListView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState

    let household: Household
    let member: HouseholdMember?

    @FetchRequest private var movies: FetchedResults<Movie>

    @State private var showingAdd = false
    @State private var didBackfill = false

    @State private var searchText = ""
    @State private var mpaaFilter: String = "All"
    @State private var selectedGenres: Set<String> = []
    @State private var showGenrePicker = false
    @State private var sleptOnly: Bool = false
    @State private var sleptMemberID: NSManagedObjectID? = nil

    @State private var members: [HouseholdMember] = []
    @State private var ratingByMovieID: [NSManagedObjectID: RatingSummary] = [:]
    @State private var sleptMovieIDs: Set<NSManagedObjectID> = []
    @State private var saveError: String?

    private var canWrite: Bool {
        IdentityStore.canAct(as: member, appUser: appState.appUser, context: context)
    }

    private enum SortOption: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case oldest = "Oldest"
        case titleAZ = "Title A–Z"
        case yearNewOld = "Year (new→old)"
        case avgRatingHighLow = "Avg rating (high→low)"

        var id: String { rawValue }
    }

    @State private var sort: SortOption = .newest

    private let mpaaOptions: [String] = ["All", "G", "PG", "PG-13", "R", "NC-17", "Not Rated", "—"]
    private let allGenres: [String] = [
        "Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama", "Family",
        "Fantasy", "History", "Horror", "Music", "Mystery", "Romance", "Sci-Fi", "Thriller", "War", "Western"
    ]

    init(household: Household, member: HouseholdMember?) {
        self.household = household
        self.member = member

        let sort = [NSSortDescriptor(keyPath: \Movie.createdAt, ascending: false)]

        _movies = FetchRequest<Movie>(
            sortDescriptors: sort,
            predicate: householdScopedPredicate(household),
            animation: .default
        )
    }

    private var filteredMovies: [Movie] {
        var list = Array(movies)

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter { movie in
                let title = (movie.title ?? "").lowercased()
                let genre = (movie.genre ?? "").lowercased()
                let mpaa = (movie.mpaaRating ?? "").lowercased()
                let year = movie.year == 0 ? "" : String(movie.year)
                return title.contains(q) || genre.contains(q) || mpaa.contains(q) || year.contains(q)
            }
        }

        if mpaaFilter != "All" {
            list = list.filter { movie in
                let value = movie.mpaaRating ?? ""
                if mpaaFilter == "—" { return value.isEmpty }
                return value == mpaaFilter
            }
        }

        if !selectedGenres.isEmpty {
            list = list.filter { movie in
                let movieGenres = Set(
                    (movie.genre ?? "")
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
                return !movieGenres.intersection(selectedGenres).isEmpty
            }
        }

        if sleptOnly {
            list = list.filter { sleptMovieIDs.contains($0.objectID) }
        }

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

    var body: some View {
        List {
            pageTitleSection

            if filteredMovies.isEmpty {
                SharedViews.SoftEmptyState(
                    title: searchText.isEmpty ? "No movies yet" : "No results",
                    systemImage: "film.fill",
                    style: .movies,
                    description: searchText.isEmpty ? "Add your first family movie night." : "Try another title, genre, or year."
                )
                .listRowBackground(Color.clear)
            } else {
                moviesSection
            }
        }
        .navigationTitle("Movies")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(
            leading: filtersMenuButton,
            trailing: trailingButtons
        )
        .scrollContentBackground(.hidden)
        .background(AppCategoryStyle.movies.gradient.opacity(0.12))
        .searchable(text: $searchText, prompt: "Search title, genre, year…")
        .navigationDestination(isPresented: $showGenrePicker) {
            GenrePickerView(title: "Select Genres", allGenres: allGenres, selected: $selectedGenres)
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                AddMovieView(household: household, member: member)
            }
        }
        .task {
            guard !didBackfill else { return }
            didBackfill = true
            reloadMembers()
            await reloadAggregates()

            if canWrite {
#if DEBUG
                MovieStoreSafety.diagnoseMovieGraphs(household: household, context: context, reason: "MoviesListView.task")
#endif
                await backfillHouseholdIDAndPostersIfNeeded()
            }

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
        .alert("Could Not Update Movies", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }

    private var pageTitleSection: some View {
        Section {
            HStack(spacing: 12) {
                SharedViews.AccentIconBadge(systemImage: "film.fill", style: .movies)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Movies")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)

                    Text("Track family movie nights, ratings, and rewatches.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var moviesSection: some View {
        if canWrite {
            ForEach(filteredMovies) { movie in
                movieNavigationRow(movie)
            }
            .onDelete(perform: deleteMoviesFromFiltered)
        } else {
            ForEach(filteredMovies) { movie in
                movieNavigationRow(movie)
            }
        }
    }

    private func movieNavigationRow(_ movie: Movie) -> some View {
        NavigationLink {
            MovieDetailView(movie: movie, household: household, member: member)
        } label: {
            MovieRowView(
                movie: movie,
                avgText: avgHouseholdRatingText(for: movie),
                isSleptThrough: sleptOnly && sleptMovieIDs.contains(movie.objectID)
            )
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var trailingButtons: some View {
        HStack(spacing: 12) {
            EditButton()
                .disabled(!canWrite)

            Button {
                showingAdd = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Movie")
            .disabled(!canWrite)
        }
    }

    private var filtersMenuButton: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }

            Divider()

            Picker("MPAA", selection: $mpaaFilter) {
                ForEach(mpaaOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }

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

            if !members.isEmpty {
                Picker("Slept member", selection: $sleptMemberID) {
                    Text("None").tag(Optional<NSManagedObjectID>.none)
                    ForEach(members) { currentMember in
                        Text(currentMember.displayName ?? "Member").tag(Optional(currentMember.objectID))
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
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filters")
    }

    private func backfillHouseholdIDAndPostersIfNeeded() async {
        guard canWrite else { return }

        if household.id == nil {
            await MainActor.run {
                household.id = UUID()
                do {
                    context.debugLogStoreSafeSave(entityName: "Movie.householdIDBackfill.household", household: household, member: member, objects: [("household", household)])
                    try MovieStoreSafety.validateHouseholdMovieGraphs(household: household, context: context, operation: "Movie.householdIDBackfill.household")
                    try context.save()
                } catch {
                    context.rollback()
                    saveError = error.localizedDescription
                    print("❌ [MovieBackfill] household save blocked:", error)
                }
            }
        }

        guard let householdID = household.id else { return }

        await MainActor.run {
            let request = NSFetchRequest<Movie>(entityName: "Movie")
            request.predicate = NSPredicate(format: "household == %@ AND householdID == nil", household)

            if let legacyMovies = try? context.fetch(request), !legacyMovies.isEmpty {
                do {
                    for movie in legacyMovies {
                        movie.householdID = householdID
                        try MovieStoreSafety.validateMovieGraph(movie: movie, household: household, context: context, operation: "Movie.householdIDBackfill")
                    }
                    try context.save()
                } catch {
                    context.rollback()
                    saveError = error.localizedDescription
                    print("❌ [MovieBackfill] householdID save blocked:", error)
                }
            }
        }

        let missingPosterMovies: [Movie] = await MainActor.run {
            let request = NSFetchRequest<Movie>(entityName: "Movie")
            request.predicate = NSPredicate(format: "household == %@ AND (posterURL == nil OR posterURL == '')", household)
            return (try? context.fetch(request)) ?? []
        }

        guard !missingPosterMovies.isEmpty else { return }

        var updates: [(NSManagedObjectID, String)] = []

        for movie in missingPosterMovies {
            let fetched = await OMDbPosterService.posterURL(title: movie.title, year: movie.year)
            guard let fetched else { continue }
            updates.append((movie.objectID, fetched.absoluteString))
        }

        guard !updates.isEmpty else { return }

        await MainActor.run {
            for (objectID, urlString) in updates {
                if let movie = try? context.existingObject(with: objectID) as? Movie {
                    movie.posterURL = urlString
                    do {
                        try MovieStoreSafety.validateMovieGraph(movie: movie, household: movie.household, context: context, operation: "Movie.posterBackfill")
                    } catch {
                        context.rollback()
                        saveError = error.localizedDescription
                        print("❌ [MoviePosterBackfill] save blocked:", error)
                        return
                    }
                }
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                saveError = error.localizedDescription
                print("❌ [MoviePosterBackfill] save failed:", error)
            }
        }
    }

    private func reloadMembers() {
        let request = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        request.predicate = householdScopedPredicate(household)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        members = (try? context.fetch(request)) ?? []
    }

    private func reloadAggregates() async {
        await reloadRatingAggregates()
        await reloadSleptAggregates()
    }

    private func reloadRatingAggregates() async {
        await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "MovieFeedback")
            request.predicate = NSPredicate(format: "household == %@ AND rating > 0", household)
            request.resultType = .dictionaryResultType

            let avgExpression = NSExpressionDescription()
            avgExpression.name = "avgRating"
            avgExpression.expression = NSExpression(
                forFunction: "average:",
                arguments: [NSExpression(forKeyPath: "rating")]
            )
            avgExpression.expressionResultType = .doubleAttributeType

            let countExpression = NSExpressionDescription()
            countExpression.name = "countRating"
            countExpression.expression = NSExpression(
                forFunction: "count:",
                arguments: [NSExpression(forKeyPath: "rating")]
            )
            countExpression.expressionResultType = .integer64AttributeType

            request.propertiesToFetch = ["movie", avgExpression, countExpression]
            request.propertiesToGroupBy = ["movie"]

            let results = (try? context.fetch(request)) ?? []
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
        guard sleptOnly,
              let sleptMemberID,
              let selectedMember = members.first(where: { $0.objectID == sleptMemberID }) else {
            await MainActor.run { sleptMovieIDs = [] }
            return
        }

        await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "MovieFeedback")
            request.predicate = NSPredicate(
                format: "household == %@ AND member == %@ AND slept == YES",
                household,
                selectedMember
            )
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["movie"]
            request.propertiesToGroupBy = ["movie"]

            let results = (try? context.fetch(request)) ?? []
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

    private func deleteMoviesFromFiltered(offsets: IndexSet) {
        guard canWrite else { return }
        let toDelete = offsets.map { filteredMovies[$0] }
        do {
            for movie in toDelete {
                try MovieStoreSafety.validateMovieDelete(movie: movie, context: context)
                context.delete(movie)
            }
            try context.save()
        } catch {
            context.rollback()
            saveError = error.localizedDescription
            print("Delete movie failed:", error)
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            print("Save failed:", error)
        }
    }
}

private struct RatingSummary {
    let avg: Double
    let count: Int
}

private struct MovieRowView: View {
    let movie: Movie
    let avgText: String?
    let isSleptThrough: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PosterThumb(movie: movie)

            VStack(alignment: .leading, spacing: 4) {
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

                if let avgText {
                    Text(avgText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if isSleptThrough {
                    Text("😴 Slept through")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .subtleCategoryRowCard(style: .movies, horizontalPadding: 9, verticalPadding: 6)
    }
}

private struct PosterThumb: View {
    let movie: Movie
    @State private var url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(AppCategoryStyle.movies.gradient)

            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "film")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 66)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .task(id: movie.objectID) {
            if let posterURL = movie.posterURL,
               !posterURL.isEmpty,
               let savedURL = URL(string: posterURL) {
                url = savedURL
                return
            }

            let fetched = await OMDbPosterService.posterURL(title: movie.title, year: movie.year)
            url = fetched

            if fetched != nil {
                await MainActor.run {
                    // Read-only list rendering should not persist writes for unauthorized viewers.
                    // Poster persistence is handled in write-authorized paths.
                }
            }
        }
    }
}
