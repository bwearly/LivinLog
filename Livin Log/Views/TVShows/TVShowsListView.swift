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
    @EnvironmentObject private var appState: AppState

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
        case ratingHighLow = "Rating (high→low)"

        var id: String { rawValue }
    }

    @State private var sort: SortOption = .newest

    private var canWrite: Bool {
        IdentityStore.canAct(as: member, appUser: appState.appUser, context: context)
    }

    init(household: Household, member: HouseholdMember?) {
        self.household = household
        self.member = member

        let sortDescriptors = [NSSortDescriptor(keyPath: \TVShow.createdAt, ascending: false)]

        _tvShows = FetchRequest<TVShow>(
            sortDescriptors: sortDescriptors,
            predicate: householdScopedPredicate(household),
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
            list.sort { ratingRank($0.ratingText) > ratingRank($1.ratingText) }
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
                showsSection
            }
        }
        .navigationTitle("TV Shows")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(
            leading: sortMenuButton,
            trailing: trailingButtons
        )
        .searchable(text: $searchText, prompt: "Search title, year, seasons, rating, notes…")
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                AddTVShowView(household: household, member: member)
            }
        }
        .task {
            guard !didBackfill else { return }
            didBackfill = true

            if canWrite {
                await backfillHouseholdIDIfNeeded()
            }
        }
        .task {
            if canWrite {
                await fetchMissingPostersIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var showsSection: some View {
        if canWrite {
            ForEach(filteredShows, id: \.objectID) { show in
                showNavigationRow(show)
            }
            .onDelete(perform: deleteShowsFromFiltered)
        } else {
            ForEach(filteredShows, id: \.objectID) { show in
                showNavigationRow(show)
            }
        }
    }

    private func showNavigationRow(_ show: TVShow) -> some View {
        NavigationLink {
            TVShowDetailView(tvShow: show, household: household, member: member)
        } label: {
            TVShowRowView(
                show: show,
                ratingText: ratingDisplay(show.ratingText)
            )
        }
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
            .accessibilityLabel("Add TV Show")
            .disabled(!canWrite)
        }
    }

    private var sortMenuButton: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(SortOption.allCases) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
    }

    // MARK: - Rating display + sorting

    private func ratingDisplay(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    private func ratingRank(_ value: String?) -> Int {
        let v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        switch v {
        case "TV-Y": return 10
        case "TV-Y7": return 20
        case "TV-G": return 30
        case "TV-PG": return 40
        case "TV-14": return 50
        case "TV-MA": return 60
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
        let needsPoster = filteredShows.filter {
            let s = ($0.posterURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty
        }

        guard !needsPoster.isEmpty else { return }

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
                for show in legacy {
                    show.householdID = hid
                }
                try? context.save()
            }
        }
    }

    private func deleteShowsFromFiltered(offsets: IndexSet) {
        guard canWrite else { return }

        let toDelete = offsets.compactMap { idx -> TVShow? in
            guard filteredShows.indices.contains(idx) else { return nil }
            return filteredShows[idx]
        }

        do {
            for show in toDelete {
                try context.validateSamePersistentStore([("tvShow", show), ("household", show.household)])
                context.delete(show)
            }
            try context.save()
        } catch {
            context.rollback()
            print("Delete TV show failed:", error)
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

private struct TVShowRowView: View {
    let show: TVShow
    let ratingText: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TVPosterThumb(tvShow: show)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(show.title ?? "Untitled")
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    Text(ratingText)
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

// MARK: - Poster Thumb

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
