//
//  AnalyticsView.swift
//  Livin Log
//

import SwiftUI
import CoreData

struct AnalyticsView: View {
    @Environment(\.managedObjectContext) private var context

    let household: Household
    let member: HouseholdMember?

    @State private var members: [HouseholdMember] = []
    @State private var movies: [Movie] = []
    @State private var books: [BookEntry] = []
    @State private var feedbacks: [MovieFeedback] = []
    @State private var events: [DashboardActivity] = []
    @State private var selectedMemberID: NSManagedObjectID?
    @State private var timeFilter: AnalyticsTimeFilter = .allTime
    @State private var appeared = false
    @State private var loadError: String?

    private var filteredBooks: [BookEntry] {
        books.filter { book in
            memberMatches(book.ownerMember) && dateMatches(book.finishedAt ?? book.createdAt)
        }
    }

    private var filteredFeedbacks: [MovieFeedback] {
        feedbacks.filter { feedback in
            memberMatches(feedback.member) && dateMatches(feedback.updatedAt)
        }
    }

    private var filteredMovies: [Movie] {
        movies.filter { movie in dateMatches(movie.createdAt) }
    }

    private var filteredEvents: [DashboardActivity] {
        events.filter { event in
            if let selectedMemberID, event.memberID != selectedMemberID { return false }
            return dateMatches(event.date)
        }
        .sorted { $0.date > $1.date }
    }

    private var averageMovieRating: Double? {
        average(filteredFeedbacks.map(\.rating).filter { $0 > 0 })
    }

    private var averageBookRating: Double? {
        average(filteredBooks.map(\.rating).filter { $0 > 0 })
    }

    private var highestMovie: (title: String, rating: Double)? {
        filteredFeedbacks
            .filter { $0.rating > 0 }
            .sorted { $0.rating > $1.rating }
            .first
            .map { ($0.movie?.title ?? "Untitled movie", $0.rating) }
    }

    private var highestBook: (title: String, rating: Double)? {
        filteredBooks
            .filter { $0.rating > 0 }
            .sorted { $0.rating > $1.rating }
            .first
            .map { ($0.title ?? "Untitled book", $0.rating) }
    }

    private var thisMonthCount: Int {
        let calendar = Calendar.current
        let now = Date()
        return events.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }.count
    }

    private var balance: (books: Int, movies: Int) {
        (filteredBooks.count, filteredMovies.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                filters

                if let loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                }

                statGrid
                highlights
                balanceCard
                memberLeaderboard
                ratingDistribution
                genreCloud
                recentActivity
                emptyStateIfNeeded
            }
            .padding()
        }
        .background(dashboardBackground.ignoresSafeArea())
        .navigationTitle("Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reloadAll()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
                appeared = true
            }
        }
        .onChange(of: timeFilter) { _, _ in animateRefresh() }
        .onChange(of: selectedMemberID) { _, _ in animateRefresh() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(household.name ?? "Household")
                        .font(.largeTitle.bold())
                    Text("Your family story at a glance")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles")
                    .font(.title.bold())
                    .foregroundStyle(.yellow)
                    .padding(14)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Text("\(thisMonthCount) logs this month • \(members.count) profile\(members.count == 1 ? "" : "s")")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [Color.indigo.opacity(0.88), Color.purple.opacity(0.72), Color.cyan.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 76, weight: .semibold))
                .foregroundStyle(.white.opacity(0.10))
                .padding(.trailing, 18)
                .padding(.bottom, 12)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .scaleEffect(appeared ? 1 : 0.96)
        .opacity(appeared ? 1 : 0)
    }

    private var filters: some View {
        VStack(spacing: 10) {
            Picker("Time", selection: $timeFilter) {
                ForEach(AnalyticsTimeFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            Picker("Member", selection: $selectedMemberID) {
                Text("All").tag(Optional<NSManagedObjectID>.none)
                ForEach(members, id: \.objectID) { member in
                    Text(member.displayName ?? "Member").tag(Optional(member.objectID))
                }
            }
            .pickerStyle(.menu)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            DashboardStatCard(title: "Movies", value: String(filteredMovies.count), icon: "film.fill", colors: [.pink, .orange])
            DashboardStatCard(title: "Books", value: String(filteredBooks.count), icon: "books.vertical.fill", colors: [.indigo, .blue])
            DashboardStatCard(title: "Avg Movie", value: ratingText(averageMovieRating), icon: "star.fill", colors: [.yellow, .orange])
            DashboardStatCard(title: "Avg Book", value: ratingText(averageBookRating), icon: "bookmark.fill", colors: [.mint, .green])
        }
    }

    private var highlights: some View {
        DashboardSectionCard(title: "Top Highlights", icon: "crown.fill") {
            VStack(spacing: 12) {
                HighlightRow(label: "Highest rated movie", title: highestMovie?.title ?? "No movie ratings yet", detail: highestMovie.map { ratingText($0.rating) } ?? "Add ratings to unlock this")
                Divider().opacity(0.35)
                HighlightRow(label: "Highest rated book", title: highestBook?.title ?? "No book ratings yet", detail: highestBook.map { ratingText($0.rating) } ?? "Add books to unlock this")
            }
        }
    }

    private var balanceCard: some View {
        let total = max(balance.books + balance.movies, 1)
        let bookRatio = CGFloat(balance.books) / CGFloat(total)
        return DashboardSectionCard(title: "Reading vs Watching", icon: "chart.pie.fill") {
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.gradient)
                            .frame(width: max(proxy.size.width * bookRatio, balance.books == 0 ? 0 : 8))
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.pink.gradient)
                    }
                }
                .frame(height: 14)
                HStack {
                    Label("\(balance.books) books", systemImage: "book.closed.fill")
                    Spacer()
                    Label("\(balance.movies) movies", systemImage: "film.fill")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var memberLeaderboard: some View {
        DashboardSectionCard(title: "Member Leaderboard", icon: "person.3.fill") {
            let rows = members.map { member in
                let bookCount = filteredBooks.filter { $0.ownerMember?.objectID == member.objectID }.count
                let movieCount = filteredFeedbacks.filter { $0.member?.objectID == member.objectID }.count
                return (member, bookCount, movieCount, bookCount + movieCount)
            }
            .sorted { $0.3 > $1.3 }

            if rows.isEmpty {
                FriendlyEmptyLine(text: "Profiles will appear here once CloudKit finishes syncing.")
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 12) {
                            Text("#\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading) {
                                Text(row.0.displayName ?? "Member")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(row.1) books • \(row.2) movie ratings")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(row.3)")
                                .font(.title3.bold())
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var ratingDistribution: some View {
        DashboardSectionCard(title: "Rating Distribution", icon: "chart.bar.fill") {
            let buckets = ratingBuckets()
            if buckets.allSatisfy({ $0.count == 0 }) {
                FriendlyEmptyLine(text: "Rate a few movies or books to see the vibe curve.")
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(buckets) { bucket in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(bucket.color.gradient)
                                .frame(height: CGFloat(max(bucket.count, 1)) * 16)
                            Text(bucket.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 120)
            }
        }
    }

    private var genreCloud: some View {
        DashboardSectionCard(title: "Favorite Genres", icon: "theatermasks.fill") {
            let genres = favoriteGenres()
            if genres.isEmpty {
                FriendlyEmptyLine(text: "Movie genres will show here as your household logs more titles.")
            } else {
                FlowLayout(items: genres.prefix(8).map { "\($0.name) \($0.count)" })
            }
        }
    }

    private var recentActivity: some View {
        DashboardSectionCard(title: "Recent Activity", icon: "clock.fill") {
            let recent = Array(filteredEvents.prefix(8))
            if recent.isEmpty {
                FriendlyEmptyLine(text: "No recent logs for this filter. Try All time or add something new.")
            } else {
                VStack(spacing: 12) {
                    ForEach(recent) { activity in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(activity.tint.opacity(0.16))
                                Image(systemName: activity.icon)
                                    .foregroundStyle(activity.tint)
                            }
                            .frame(width: 42, height: 42)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(activity.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(activity.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(activity.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyStateIfNeeded: some View {
        if filteredBooks.isEmpty && filteredMovies.isEmpty && filteredFeedbacks.isEmpty {
            ContentUnavailableView(
                "Analytics are warming up",
                systemImage: "chart.xyaxis.line",
                description: Text("Add a book, movie, or rating and this dashboard will become your family's activity recap.")
            )
            .padding(.top, 10)
        }
    }

    private var dashboardBackground: some View {
        LinearGradient(
            colors: [Color(.systemBackground), Color.indigo.opacity(0.10), Color.purple.opacity(0.08)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func reloadAll() {
        loadError = nil
        do {
            members = try fetchMembers()
            movies = try fetchMovies()
            books = try fetchBooks()
            feedbacks = try fetchFeedbacks()
            if let selectedMemberID, !members.contains(where: { $0.objectID == selectedMemberID }) {
                self.selectedMemberID = nil
            }
            events = makeEvents()
        } catch {
            loadError = "Analytics could not load everything yet. iCloud may still be syncing."
#if DEBUG
            print("📊 [Analytics] reload failed: \(error)")
#endif
        }
    }

    private func fetchMembers() throws -> [HouseholdMember] {
        let req = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        req.predicate = householdScopedPredicate(household)
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return try context.fetch(req)
    }

    private func fetchMovies() throws -> [Movie] {
        let req = NSFetchRequest<Movie>(entityName: "Movie")
        req.predicate = householdScopedPredicate(household)
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(req)
    }

    private func fetchBooks() throws -> [BookEntry] {
        let req = NSFetchRequest<BookEntry>(entityName: "BookEntry")
        req.predicate = householdScopedPredicate(household)
        req.sortDescriptors = [NSSortDescriptor(key: "finishedAt", ascending: false), NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(req)
    }

    private func fetchFeedbacks() throws -> [MovieFeedback] {
        let req = NSFetchRequest<MovieFeedback>(entityName: "MovieFeedback")
        req.predicate = householdScopedPredicate(household)
        req.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return try context.fetch(req)
    }

    private func makeEvents() -> [DashboardActivity] {
        var activity: [DashboardActivity] = []
        for book in books {
            let date = book.finishedAt ?? book.createdAt ?? Date.distantPast
            activity.append(DashboardActivity(
                title: book.title ?? "Untitled book",
                subtitle: "Book • \(book.ownerMember?.displayName ?? "Household")",
                date: date,
                memberID: book.ownerMember?.objectID,
                icon: "book.closed.fill",
                tint: .blue
            ))
        }
        for movie in movies {
            activity.append(DashboardActivity(
                title: movie.title ?? "Untitled movie",
                subtitle: movie.year == 0 ? "Movie" : "Movie • \(Int(movie.year))",
                date: movie.createdAt ?? Date.distantPast,
                memberID: nil,
                icon: "film.fill",
                tint: .pink
            ))
        }
        for feedback in feedbacks where feedback.rating > 0 {
            activity.append(DashboardActivity(
                title: feedback.movie?.title ?? "Movie rating",
                subtitle: "\(feedback.member?.displayName ?? "Member") rated \(ratingText(feedback.rating))",
                date: feedback.updatedAt ?? Date.distantPast,
                memberID: feedback.member?.objectID,
                icon: "star.fill",
                tint: .yellow
            ))
        }
        return activity.sorted { $0.date > $1.date }
    }

    private func memberMatches(_ candidate: HouseholdMember?) -> Bool {
        guard let selectedMemberID else { return true }
        return candidate?.objectID == selectedMemberID
    }

    private func dateMatches(_ date: Date?) -> Bool {
        guard let date else { return false }
        let calendar = Calendar.current
        let now = Date()
        switch timeFilter {
        case .allTime:
            return true
        case .thisMonth:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .thisYear:
            return calendar.isDate(date, equalTo: now, toGranularity: .year)
        }
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func ratingText(_ rating: Double?) -> String {
        guard let rating else { return "—" }
        return String(format: "%.1f", rating)
    }

    private func ratingBuckets() -> [RatingBucket] {
        let ratings = filteredBooks.map(\.rating).filter { $0 > 0 } + filteredFeedbacks.map(\.rating).filter { $0 > 0 }
        let ranges: [(String, ClosedRange<Double>, Color)] = [
            ("0-2", 0...2, .red),
            ("3-4", 2.0001...4, .orange),
            ("5-6", 4.0001...6, .yellow),
            ("7-8", 6.0001...8, .blue),
            ("9-10", 8.0001...10, .green)
        ]
        return ranges.map { label, range, color in
            RatingBucket(label: label, count: ratings.filter { range.contains($0) }.count, color: color)
        }
    }

    private func favoriteGenres() -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for movie in filteredMovies {
            let parts = (movie.genre ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for part in parts { counts[part, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
        }
    }

    private func animateRefresh() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            appeared = true
        }
    }
}

private enum AnalyticsTimeFilter: String, CaseIterable, Identifiable {
    case allTime
    case thisMonth
    case thisYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTime: return "All"
        case .thisMonth: return "Month"
        case .thisYear: return "Year"
        }
    }
}

private struct DashboardActivity: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let date: Date
    let memberID: NSManagedObjectID?
    let icon: String
    let tint: Color
}

private struct RatingBucket: Identifiable {
    let id = UUID()
    let label: String
    let count: Int
    let color: Color
}

private struct DashboardStatCard: View {
    let title: String
    let value: String
    let icon: String
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                Spacer()
            }
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }
}

private struct DashboardSectionCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
            }
            content
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }
}

private struct HighlightRow: View {
    let label: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            Text(detail)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
        }
    }
}

private struct FriendlyEmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

private struct FlowLayout: View {
    let items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }
        }
    }
}
