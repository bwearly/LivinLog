import SwiftUI
import CoreData

struct HomeDashboardView: View {
    @Environment(\.managedObjectContext) private var context

    @State var household: Household?
    @State var member: HouseholdMember?

    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    moviesCard
                    tvShowsCard
                    datesCard
                    analyticsCard
                }
                .padding(16)
            }
            .navigationTitle("Livin Log")
            .toolbar {
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
            restoreOrAutoPickSelection()
        }
        .onChange(of: household?.objectID) { _, _ in
            normalizeSelection()
            SelectionStore.save(household: household, member: member)
        }
        .onChange(of: member?.objectID) { _, _ in
            normalizeSelection()
            SelectionStore.save(household: household, member: member)
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
                destination: MoviesListView(household: household, member: member)
            )
        } else {
            SharedViews.SectionCard(
                title: "Movies",
                subtitle: "Select a household first",
                systemImage: "film",
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
                destination: TVShowsListView(household: household, member: member)
            )
        } else {
            SharedViews.SectionCard(
                title: "TV Shows",
                subtitle: "Select a household first",
                systemImage: "tv",
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
                destination: CalendarMainView(household: household)
            )
        } else {
            SharedViews.SectionCard(
                title: "Dates",
                subtitle: "Select a household first",
                systemImage: "calendar",
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
                subtitle: "Trends & stats",
                systemImage: "chart.bar",
                destination: AnalyticsView(household: household, member: member)
            )
        } else {
            SharedViews.SectionCard(
                title: "Analytics",
                subtitle: "Select a household first",
                systemImage: "chart.bar",
                destination: SharedViews.PlaceholderView(title: "Select Household")
            )
            .opacity(0.6)
        }
    }

    // MARK: - Selection + Auto-heal

    private func restoreOrAutoPickSelection() {
        let (h, m) = SelectionStore.load(context: context)
        self.household = h
        self.member = m
        normalizeSelection()

        // If still nil (first launch), auto-pick first household and member
        if self.household == nil {
            if let firstHousehold = fetchFirstHousehold() {
                self.household = firstHousehold
            }
        }
        normalizeSelection()
        SelectionStore.save(household: household, member: member)
    }

    /// Ensures:
    /// - if household exists, it has at least 1 member ("Me")
    /// - member is non-nil and belongs to the selected household
    private func normalizeSelection() {
        guard let hh = household else {
            member = nil
            return
        }

        // Ensure at least one member exists
        let members = fetchMembers(for: hh)
        if members.isEmpty {
            let me = HouseholdMember(context: context)
            me.id = UUID()
            me.createdAt = Date()
            me.displayName = "Me"
            me.household = hh

            do { try context.save() } catch { context.rollback() }
        }

        let updatedMembers = fetchMembers(for: hh)

        // If member is nil or belongs to a different household, pick first
        if member == nil || member?.household?.objectID != hh.objectID {
            member = updatedMembers.first
        }
    }

    private func fetchFirstHousehold() -> Household? {
        let req = NSFetchRequest<Household>(entityName: "Household")
        req.fetchLimit = 1
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return try? context.fetch(req).first
    }

    private func fetchMembers(for household: Household) -> [HouseholdMember] {
        let req = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        req.predicate = NSPredicate(format: "household == %@", household)
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return (try? context.fetch(req)) ?? []
    }
}
