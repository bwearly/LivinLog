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
    @State private var operationError: String?

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

    private var fetchedShowObjectIDURIs: [String] {
        tvShows.map { $0.objectID.uriRepresentation().absoluteString }
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
                SharedViews.SoftEmptyState(
                    title: searchText.isEmpty ? "No TV shows yet" : "No results",
                    systemImage: "tv.fill",
                    style: .tvShows,
                    description: searchText.isEmpty ? "Add a show your household is watching." : "Try another title, year, season count, or rating."
                )
                .listRowBackground(Color.clear)
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
        .scrollContentBackground(.hidden)
        .background(AppCategoryStyle.tvShows.gradient.opacity(0.12))
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
                await repairTVShowHouseholdLinksIfNeeded()
            }
#if DEBUG
            debugLogFetchedShows(reason: "listAppear")
            if let scopedHousehold = activeHouseholdInContext(household, context: context) {
                TVShowStoreSafety.diagnoseTVShowGraphs(household: scopedHousehold, context: context, reason: "listAppear.household")
            }
            TVShowStoreSafety.diagnoseTVShowGraphs(household: nil, context: context, reason: "listAppear.allTVShows")
#endif
        }
        .onChange(of: fetchedShowObjectIDURIs) { _, _ in
#if DEBUG
            debugLogFetchedShows(reason: "fetchChange")
#endif
        }
        .task {
            if canWrite {
                await fetchMissingPostersIfNeeded()
            }
        }
        .alert("TV Show Update Failed", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "The TV show could not be updated.")
        }
    }

#if DEBUG
    private func debugLogFetchedShows(reason: String) {
        let active = activeHouseholdInContext(household, context: context)
        print("📺 [TVShowsList] reason=\(reason) activeHousehold name=\(active?.name ?? household.name ?? "<unnamed>") id=\(active?.id?.uuidString ?? household.id?.uuidString ?? "<nil>") objectID=\((active ?? household).objectID.uriRepresentation().absoluteString)")
        print("📺 [TVShowsList] reason=\(reason) fetchedCount=\(tvShows.count) filteredCount=\(filteredShows.count)")
        for show in tvShows {
            print("📺 [TVShowsList] fetched title=\(show.title ?? "<untitled>") year=\(Int(show.year)) objectID=\(show.objectID.uriRepresentation().absoluteString) householdID=\(show.householdID?.uuidString ?? "<nil>") store=\(storeDebugDescription(show.objectID.persistentStore))")
        }
    }
#endif

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
        let needsPoster = filteredShows.compactMap { show -> (NSManagedObjectID, String?, Int16)? in
            let s = (show.posterURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? (show.objectID, show.title, show.year) : nil
        }

        guard !needsPoster.isEmpty else { return }

        for snapshot in needsPoster.prefix(20) {
            let fetched = await OMDbPosterService.posterURL(title: snapshot.1, year: snapshot.2)
            guard let fetched else { continue }

            await MainActor.run {
                guard let showInContext = (try? context.existingObject(with: snapshot.0)) as? TVShow else { return }
                showInContext.posterURL = fetched.absoluteString
                do {
                    try TVShowStoreSafety.validateGraph(tvShow: showInContext, context: context, operation: "TVShow.poster.listBackfill")
                    try context.save()
                } catch {
                    context.rollback()
                    operationError = "Could not save a TV show poster: \(error.localizedDescription)"
                    print("❌ [TVShowPosterBackfill] save blocked:", error)
                }
            }
        }
    }

    // MARK: - Backfill + delete

    private func repairTVShowHouseholdLinksIfNeeded() async {
        await MainActor.run {
            guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
                operationError = "Could not resolve the active household."
                return
            }

            if scopedHousehold.id == nil {
                scopedHousehold.id = UUID()
            }

            guard let hid = scopedHousehold.id else { return }

            let missingHouseholdIDRequest = NSFetchRequest<TVShow>(entityName: "TVShow")
            missingHouseholdIDRequest.predicate = NSPredicate(format: "household == %@ AND householdID == nil", scopedHousehold)
            missingHouseholdIDRequest.includesPendingChanges = true

            let orphanedByOldToOneRequest = NSFetchRequest<TVShow>(entityName: "TVShow")
            orphanedByOldToOneRequest.predicate = NSPredicate(format: "household == nil AND householdID == %@", hid as NSUUID)
            orphanedByOldToOneRequest.includesPendingChanges = true

            do {
                let missingHouseholdID = try context.fetch(missingHouseholdIDRequest)
                let orphanedByOldToOne = try context.fetch(orphanedByOldToOneRequest)
                guard !missingHouseholdID.isEmpty || !orphanedByOldToOne.isEmpty || context.hasChanges else { return }

                for show in missingHouseholdID {
                    try TVShowStoreSafety.validateGraph(tvShow: show, context: context, operation: "TVShow.householdIDBackfill.preflight")
                    show.householdID = hid
                    try TVShowStoreSafety.validateGraph(tvShow: show, context: context, operation: "TVShow.householdIDBackfill")
                }

                for show in orphanedByOldToOne {
                    try context.validateSamePersistentStore([("orphanedTVShow", show), ("household", scopedHousehold)])
                    show.household = scopedHousehold
                    try TVShowStoreSafety.validateGraph(tvShow: show, context: context, operation: "TVShow.householdRelink")
#if DEBUG
                    print("📺 [TVShowBackfill] relinked orphaned show title=\(show.title ?? "<untitled>") year=\(Int(show.year)) objectID=\(show.objectID.uriRepresentation().absoluteString) householdID=\(hid.uuidString)")
#endif
                }

                try context.save()
            } catch {
                context.rollback()
                operationError = "Could not repair TV show household links: \(error.localizedDescription)"
                print("❌ [TVShowBackfill] save blocked:", error)
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
                guard let showInContext = (try? context.existingObject(with: show.objectID)) as? TVShow else { continue }
                try TVShowStoreSafety.validateDelete(tvShow: showInContext, context: context)
                context.delete(showInContext)
            }
            try context.save()
        } catch {
            context.rollback()
            operationError = "Could not delete TV show: \(error.localizedDescription)"
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
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(AppCategoryStyle.tvShows.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .fill(AppCategoryStyle.tvShows.gradient)

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
