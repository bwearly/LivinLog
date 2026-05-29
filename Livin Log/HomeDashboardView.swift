import SwiftUI
import CoreData

struct HomeDashboardView: View {
    @Environment(\.managedObjectContext) private var context

    @Binding var household: Household?
    @Binding var member: HouseholdMember?

    @State private var showingSettings = false
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let household {
                    QuoteOfDayCard(household: household)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                }

                LazyVGrid(columns: gridColumns, spacing: 16) {
                    booksCard
                    datesCard
                    moviesCard
                    puzzlesCard
                    quotesCard
                    tvShowsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                analyticsCard
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 16)
            }
            .navigationTitle("Livin Log")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { refreshDashboard() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("Refresh Dashboard")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView(household: $household, member: $member)
                }
            }
        }
        .onAppear {
            debugLog("onAppear")
        }
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16)
        ]
    }

    // MARK: - Dashboard Cards (broken out to help the compiler)

    @ViewBuilder
    private var moviesCard: some View {
        if let household {
            SharedViews.SectionCard(
                title: "Movies",
                subtitle: "Track what you watch",
                systemImage: "film",
                style: .movies,
                destination: MoviesListView(household: household, member: member)
            )
        } else {
            SharedViews.SectionCard(
                title: "Movies",
                subtitle: "Select a household first",
                systemImage: "film",
                style: .movies,
                destination: SharedViews.PlaceholderView(title: "Select Household")
            )
            .opacity(0.6)
        }
    }

    @ViewBuilder
    private var booksCard: some View {
        if let household {
            SharedViews.SectionCard(
                title: "Books",
                subtitle: "Track what you read",
                systemImage: "books.vertical",
                style: .books,
                destination: BooksListView(household: household)
            )
        } else {
            SharedViews.SectionCard(
                title: "Books",
                subtitle: "Select a household first",
                systemImage: "books.vertical",
                style: .books,
                destination: SharedViews.PlaceholderView(title: "Select Household")
            )
            .opacity(0.6)
        }
    }

    @ViewBuilder
    private var tvShowsCard: some View {
        if let household {
            SharedViews.SectionCard(
                title: "TV Shows",
                subtitle: "Track what you watch",
                systemImage: "tv",
                style: .tvShows,
                destination: TVShowsListView(household: household, member: member)
            )
        } else {
            SharedViews.SectionCard(
                title: "TV Shows",
                subtitle: "Select a household first",
                systemImage: "tv",
                style: .tvShows,
                destination: SharedViews.PlaceholderView(title: "Select Household")
            )
            .opacity(0.6)
        }
    }

    @ViewBuilder
    private var datesCard: some View {
        if let household {
            SharedViews.SectionCard(
                title: "Dates",
                subtitle: "Important moments",
                systemImage: "calendar",
                style: .dates,
                destination: CalendarMainView(household: household)
            )
        } else {
            SharedViews.SectionCard(
                title: "Dates",
                subtitle: "Select a household first",
                systemImage: "calendar",
                style: .dates,
                destination: SharedViews.PlaceholderView(title: "Select Household")
            )
            .opacity(0.6)
        }
    }

    @ViewBuilder
    private var puzzlesCard: some View {
        if let household {
            SharedViews.SectionCard(
                title: "Puzzles",
                subtitle: "Track completed puzzles",
                systemImage: "puzzlepiece.fill",
                style: .puzzles,
                destination: PuzzlesListView(household: household, member: member)
            )
        } else {
            SharedViews.SectionCard(
                title: "Puzzles",
                subtitle: "Select a household first",
                systemImage: "puzzlepiece.fill",
                style: .puzzles,
                destination: SharedViews.PlaceholderView(title: "Select Household")
            )
            .opacity(0.6)
        }
    }


    @ViewBuilder
    private var quotesCard: some View {
        if let household {
            SharedViews.SectionCard(
                title: "Quotes",
                subtitle: "Capture household sayings",
                systemImage: "quote.bubble",
                style: .quotes,
                destination: QuotesListView(household: household)
            )
        } else {
            SharedViews.SectionCard(
                title: "Quotes",
                subtitle: "Select a household first",
                systemImage: "quote.bubble",
                style: .quotes,
                destination: SharedViews.PlaceholderView(title: "Select Household")
            )
            .opacity(0.6)
        }
    }

    @ViewBuilder
    private var analyticsCard: some View {
        if let household {
            SharedViews.SectionCard(
                title: "Analytics",
                subtitle: "Featured trends & stats",
                systemImage: "chart.bar",
                style: .analytics,
                destination: AnalyticsView(household: household, member: member)
            )
        } else {
            SharedViews.SectionCard(
                title: "Analytics",
                subtitle: "Select a household first",
                systemImage: "chart.bar",
                style: .analytics,
                destination: SharedViews.PlaceholderView(title: "Select Household")
            )
            .opacity(0.6)
        }
    }

    private func refreshDashboard() {
        guard !isRefreshing else { return }
        isRefreshing = true

        context.perform {
            context.refreshAllObjects()
        }

        if let household {
#if DEBUG
            debugPrintHouseholdDiagnostics(household: household, context: context, reason: "manual refresh")
#endif
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isRefreshing = false
        }
    }

    private func debugLog(_ message: String) {
#if DEBUG
        print("🧭 [HomeDashboardView] \(message)")
#endif
    }

}
