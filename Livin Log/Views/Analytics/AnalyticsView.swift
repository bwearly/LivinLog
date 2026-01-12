//
//  AnalyticsView.swift
//  Keeply
//

import SwiftUI
import CoreData

struct AnalyticsView: View {
    @Environment(\.managedObjectContext) private var context

    let household: Household
    let member: HouseholdMember?

    @State private var members: [HouseholdMember] = []
    @State private var totalMovies: Int = 0
    @State private var totalViewings: Int = 0
    @State private var totalRewatches: Int = 0
    @State private var avgRatingsByMember: [NSManagedObjectID: RatingAggregate] = [:]
    @State private var sleptCountsByMember: [NSManagedObjectID: Int] = [:]
    @State private var topGenres: [(String, Int)] = []
    @State private var mostRewatched: [(Movie, Int)] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCards
                ratingsCard
                sleepCard
                genresCard
                rewatchCard
            }
            .padding()
        }
        .navigationTitle("Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadAll() }
    }

    // MARK: - UI pieces

    private var headerCards: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatCard(title: "Movies", value: "\(totalMovies)")
                StatCard(title: "Viewings", value: "\(totalViewings)")
            }
            HStack(spacing: 10) {
                StatCard(title: "Rewatches", value: "\(totalRewatches)")
                StatCard(title: "Members", value: "\(members.count)")
            }
        }
    }

    private var ratingsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Average Rating per Member")
                    .font(.headline)

                if members.isEmpty {
                    Text("No members yet.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(members) { m in
                        let summary = avgRatingsByMember[m.objectID]
                        HStack {
                            Text(m.displayName ?? "Member")
                            Spacer()
                            Text(summary == nil ? "—" : "\(String(format: "%.1f", summary?.avg ?? 0))/10 (\(summary?.count ?? 0))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }

    private var sleepCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Slept-through Count per Member")
                    .font(.headline)

                if members.isEmpty {
                    Text("No members yet.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(members) { m in
                        let count = sleptCountsByMember[m.objectID] ?? 0
                        HStack {
                            Text(m.displayName ?? "Member")
                            Spacer()
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }

    private var genresCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Top Genres")
                    .font(.headline)

                if topGenres.isEmpty {
                    Text("No genres yet.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(topGenres.prefix(8), id: \.0) { g, c in
                        HStack {
                            Text(g)
                            Spacer()
                            Text("\(c)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }

    private var rewatchCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Most Rewatched Movies")
                    .font(.headline)

                if mostRewatched.isEmpty {
                    Text("No rewatches yet.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(Array(mostRewatched.prefix(5).enumerated()), id: \.offset) { idx, item in
                        let (movie, count) = item
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(movie.title ?? "Untitled")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text(movie.year == 0 ? "—" : "\(movie.year)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if idx != min(mostRewatched.count, 5) - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reload

    private func reloadAll() {
        reloadMembers()
        reloadTotals()
        reloadAverageRatings()
        reloadSleepCounts()
        reloadGenres()
        reloadMostRewatched()
    }

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

    private func reloadTotals() {
        let movieReq = NSFetchRequest<Movie>(entityName: "Movie")
        if let hid = household.id {
            movieReq.predicate = NSPredicate(format: "householdID == %@", hid as CVarArg)
        } else {
            movieReq.predicate = NSPredicate(format: "household == %@", household)
        }
        totalMovies = (try? context.count(for: movieReq)) ?? 0

        let viewingReq = NSFetchRequest<Viewing>(entityName: "Viewing")
        viewingReq.predicate = NSPredicate(format: "household == %@", household)
        totalViewings = (try? context.count(for: viewingReq)) ?? 0

        let rewatchReq = NSFetchRequest<Viewing>(entityName: "Viewing")
        rewatchReq.predicate = NSPredicate(format: "household == %@ AND isRewatch == YES", household)
        totalRewatches = (try? context.count(for: rewatchReq)) ?? 0
    }

    private func reloadAverageRatings() {
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

        req.propertiesToFetch = ["member", avgExpr, countExpr]
        req.propertiesToGroupBy = ["member"]

        let results = (try? context.fetch(req)) ?? []
        var mapped: [NSManagedObjectID: RatingAggregate] = [:]

        for dict in results {
            guard let memberID = dict["member"] as? NSManagedObjectID else { continue }
            let avg = (dict["avgRating"] as? Double) ?? 0
            let count = Int((dict["countRating"] as? Int64) ?? 0)
            mapped[memberID] = RatingAggregate(avg: avg, count: count)
        }

        avgRatingsByMember = mapped
    }

    private func reloadSleepCounts() {
        let req = NSFetchRequest<NSDictionary>(entityName: "MovieFeedback")
        req.predicate = NSPredicate(format: "household == %@ AND slept == YES", household)
        req.resultType = .dictionaryResultType

        let countExpr = NSExpressionDescription()
        countExpr.name = "sleptCount"
        countExpr.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "slept")])
        countExpr.expressionResultType = .integer64AttributeType

        req.propertiesToFetch = ["member", countExpr]
        req.propertiesToGroupBy = ["member"]

        let results = (try? context.fetch(req)) ?? []
        var mapped: [NSManagedObjectID: Int] = [:]

        for dict in results {
            guard let memberID = dict["member"] as? NSManagedObjectID else { continue }
            let count = Int((dict["sleptCount"] as? Int64) ?? 0)
            mapped[memberID] = count
        }

        sleptCountsByMember = mapped
    }

    private func reloadGenres() {
        let req = NSFetchRequest<NSDictionary>(entityName: "Movie")
        if let hid = household.id {
            req.predicate = NSPredicate(format: "householdID == %@", hid as CVarArg)
        } else {
            req.predicate = NSPredicate(format: "household == %@", household)
        }
        req.resultType = .dictionaryResultType
        req.propertiesToFetch = ["genre"]

        let results = (try? context.fetch(req)) ?? []
        var counts: [String: Int] = [:]

        for dict in results {
            let genreString = (dict["genre"] as? String) ?? ""
            let parts = genreString
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for g in parts {
                counts[g, default: 0] += 1
            }
        }

        topGenres = counts
            .map { ($0.key, $0.value) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.localizedCaseInsensitiveCompare(b.0) == .orderedAscending
            }
    }

    private func reloadMostRewatched() {
        let req = NSFetchRequest<NSDictionary>(entityName: "Viewing")
        req.predicate = NSPredicate(format: "household == %@ AND isRewatch == YES", household)
        req.resultType = .dictionaryResultType

        let countExpr = NSExpressionDescription()
        countExpr.name = "rewatchCount"
        countExpr.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "movie")])
        countExpr.expressionResultType = .integer64AttributeType

        req.propertiesToFetch = ["movie", countExpr]
        req.propertiesToGroupBy = ["movie"]

        let results = (try? context.fetch(req)) ?? []
        let counts = results.compactMap { dict -> (NSManagedObjectID, Int)? in
            guard let movieID = dict["movie"] as? NSManagedObjectID else { return nil }
            let count = Int((dict["rewatchCount"] as? Int64) ?? 0)
            return (movieID, count)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(5)

        var mapped: [(Movie, Int)] = []
        for (movieID, count) in counts {
            if let movie = try? context.existingObject(with: movieID) as? Movie {
                mapped.append((movie, count))
            }
        }

        mostRewatched = mapped
    }
}

// MARK: - Small UI component

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RatingAggregate {
    let avg: Double
    let count: Int
}
