//
//  TVShowsListView.swift
//  Livin Log
//
//  Created by Blake Early on 1/12/26.
//

import SwiftUI
import CoreData

struct TVShowsListView: View {
    @Environment(\.managedObjectContext) private var context

    let household: Household
    let member: HouseholdMember?

    @FetchRequest private var tvShows: FetchedResults<TVShow>

    @State private var showingAdd = false
    @State private var didBackfill = false

    @State private var searchText = ""

    private enum SortOption: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case oldest = "Oldest"
        case titleAZ = "Title A–Z"
        case yearNewOld = "Year (new→old)"
        case ratingHighLow = "Rating (high→low)"   // uses ratingText order (see ratingRank)

        var id: String { rawValue }
    }

    @State private var sort: SortOption = .newest

    init(household: Household, member: HouseholdMember?) {
        self.household = household
        self.member = member

        let sortDescriptors = [NSSortDescriptor(keyPath: \TVShow.createdAt, ascending: false)]

        // Ensure we have a householdID to predicate against
        if household.id == nil {
            household.id = UUID()
            try? household.managedObjectContext?.save()
        }

        _tvShows = FetchRequest<TVShow>(
            sortDescriptors: sortDescriptors,
            predicate: NSPredicate(format: "householdID == %@", household.id! as CVarArg),
            animation: .default
        )
    }

    private var filteredShows: [TVShow] {
        var list = Array(tvShows)

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter { show in
                let title = (show.title ?? "").lowercased()
                let notes = (show.notes ?? "").lowercased()
                let year = show.year == 0 ? "" : String(Int(show.year))
                let seasons = show.seasons == 0 ? "" : String(Int(show.seasons))
                let rating = (show.ratingText ?? "").lowercased()
                return title.contains(q)
                    || notes.contains(q)
                    || year.contains(q)
                    || seasons.contains(q)
                    || rating.contains(q)
            }
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
        case .ratingHighLow:
            list.sort {
                ratingRank($0.ratingText) > ratingRank($1.ratingText)
            }
        }

        return list
    }

    var body: some View {
        List {
            if filteredShows.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No TV shows yet" : "No results",
                    systemImage: "tv"
                )
            } else {
                ForEach(filteredShows, id: \.objectID) { show in
                    NavigationLink {
                        TVShowDetailView(tvShow: show, household: household, member: member)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            TVPosterThumb(tvShow: show)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(show.title ?? "Untitled")
                                        .font(.headline)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(ratingDisplay(show.ratingText))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }

                                HStack(spacing: 8) {
                                    Text(show.year == 0 ? "—" : String(Int(show.year)))
                                    Text("•")
                                    Text(show.seasons == 0 ? "—" : "\(Int(show.seasons)) seasons")
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                                if show.rewatch {
                                    Text("Rewatch")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .onDelete(perform: deleteShowsFromFiltered)
            }
        }
        .navigationTitle("TV Shows")
        .searchable(text: $searchText, prompt: "Search title, year, seasons, rating, notes…")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingAdd = true } label: {
                    Label("Add TV Show", systemImage: "plus")
                }
            }

            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(SortOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                AddTVShowView(household: household, member: member)
            }
        }
        .task {
            guard !didBackfill else { return }
            didBackfill = true
            await backfillHouseholdIDIfNeeded()
        }
        .task {
            // Best-effort background fetch for posters that are missing.
            // Keeps list fast: it only fetches when posterURL is nil/empty.
            await fetchMissingPostersIfNeeded()
        }
    }

    // MARK: - Rating display + sorting

    private func ratingDisplay(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    /// Higher = "higher rating" for sorting purposes.
    /// Works for TV ratings and (optionally) MPAA ratings if you used them.
    private func ratingRank(_ value: String?) -> Int {
        let v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // TV ratings (increasing maturity)
        switch v {
        case "TV-Y": return 10
        case "TV-Y7": return 20
        case "TV-G": return 30
        case "TV-PG": return 40
        case "TV-14": return 50
        case "TV-MA": return 60

        // MPAA (if you kept them in the picker)
        case "G": return 10
        case "PG": return 20
        case "PG-13": return 30
        case "R": return 40
        case "NC-17": return 50

        case "NOT RATED", "UNRATED", "—", "": return 0
        default: return 0
        }
    }

    // MARK: - Posters

    private func fetchMissingPostersIfNeeded() async {
        // Only fetch for a handful at a time to keep things responsive.
        // (You can bump this later.)
        let needsPoster = filteredShows.filter {
            let s = ($0.posterURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty
        }

        if needsPoster.isEmpty { return }

        // Fetch sequentially to keep it simple + avoid rate limits.
        for show in needsPoster.prefix(20) {
            let fetched = await OMDbPosterService.posterURL(title: show.title, year: show.year)
            guard let fetched else { continue }

            await MainActor.run {
                show.posterURL = fetched.absoluteString
                try? context.save()
            }
        }
    }

    // MARK: - Backfill + delete

    private func backfillHouseholdIDIfNeeded() async {
        if household.id == nil {
            await MainActor.run {
                household.id = UUID()
                try? context.save()
            }
        }
        guard let hid = household.id else { return }

        await MainActor.run {
            let req = NSFetchRequest<TVShow>(entityName: "TVShow")
            req.predicate = NSPredicate(format: "household == %@ AND householdID == nil", household)

            if let legacy = try? context.fetch(req), !legacy.isEmpty {
                for show in legacy { show.householdID = hid }
                try? context.save()
            }
        }
    }

    private func deleteShowsFromFiltered(offsets: IndexSet) {
        let toDelete = offsets.compactMap { idx -> TVShow? in
            guard filteredShows.indices.contains(idx) else { return nil }
            return filteredShows[idx]
        }
        toDelete.forEach(context.delete)
        save()
    }

    private func save() {
        do { try context.save() }
        catch { print("Save failed:", error) }
    }
}

// MARK: - Poster Thumb (uses tvShow.posterURL stored in Core Data)

private struct TVPosterThumb: View {
    let tvShow: TVShow

    private var url: URL? {
        let s = (tvShow.posterURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return URL(string: s)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))

            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .scaleEffect(0.8)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image(systemName: "tv")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "tv")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 50, height: 70)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}
