//
//  TVShowsListView.swift
//  Keeply
//
//  Created by Blake Early on 1/5/26.
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
        case ratingHighLow = "Rating (high→low)"

        var id: String { rawValue }
    }

    @State private var sort: SortOption = .newest

    init(household: Household, member: HouseholdMember?) {
        self.household = household
        self.member = member

        let sort = [NSSortDescriptor(keyPath: \TVShow.createdAt, ascending: false)]

        if household.id == nil {
            household.id = UUID()
            try? household.managedObjectContext?.save()
        }

        _tvShows = FetchRequest<TVShow>(
            sortDescriptors: sort,
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
                let year = show.year == 0 ? "" : String(show.year)
                let seasons = show.seasons == 0 ? "" : String(show.seasons)
                return title.contains(q) || notes.contains(q) || year.contains(q) || seasons.contains(q)
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
            list.sort { $0.rating > $1.rating }
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
                ForEach(filteredShows) { show in
                    NavigationLink {
                        TVShowDetailView(tvShow: show, household: household, member: member)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(show.title ?? "Untitled")
                                    .font(.headline)
                                    .lineLimit(1)

                                Spacer()

                                Text(ratingText(show.rating))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }

                            HStack(spacing: 8) {
                                Text(show.year == 0 ? "—" : String(show.year))
                                Text("•")
                                Text(show.seasons == 0 ? "—" : "\(show.seasons) seasons")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                            if show.rewatch {
                                Text("Rewatch")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .onDelete(perform: deleteShowsFromFiltered)
            }
        }
        .navigationTitle("TV Shows")
        .searchable(text: $searchText, prompt: "Search title, year, notes…")
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
    }

    private func ratingText(_ value: Double) -> String {
        if value == 0 { return "0/10" }
        return String(format: "%.2f/10", value)
    }

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
        let toDelete = offsets.map { filteredShows[$0] }
        toDelete.forEach(context.delete)
        save()
    }

    private func save() {
        do { try context.save() }
        catch { print("Save failed:", error) }
    }
}
