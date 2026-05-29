import SwiftUI
import CoreData
import UIKit

struct PuzzlesListView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState
    let household: Household
    let member: HouseholdMember?

    @FetchRequest private var puzzles: FetchedResults<LLPuzzle>

    @State private var showingAddPuzzle = false
    @State private var searchText = ""
    private var canWrite: Bool {
        IdentityStore.canAct(as: member, appUser: appState.appUser, context: context)
    }

    init(household: Household, member: HouseholdMember?) {
        self.household = household
        self.member = member

        _puzzles = FetchRequest<LLPuzzle>(
            sortDescriptors: [
                NSSortDescriptor(keyPath: \LLPuzzle.completedAt, ascending: false),
                NSSortDescriptor(keyPath: \LLPuzzle.createdAt, ascending: false)
            ],
            predicate: NSPredicate(format: "household == %@", household),
            animation: .default
        )
    }

    private var filteredPuzzles: [LLPuzzle] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return Array(puzzles) }

        return puzzles.filter { puzzle in
            (puzzle.name ?? "").lowercased().contains(query)
            || (puzzle.brand ?? "").lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            if filteredPuzzles.isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SharedViews.SoftEmptyState(
                        title: "No puzzles yet",
                        systemImage: "puzzlepiece.fill",
                        style: .puzzles,
                        description: "Add your first puzzle and celebrate every completed solve."
                    )
                    .listRowBackground(Color.clear)

                    Button("Add Puzzle") {
                        showingAddPuzzle = true
                    }
                    .foregroundStyle(AppCategoryStyle.puzzles.accent)
                    .disabled(!canWrite)
                    .listRowBackground(Color.clear)
                } else {
                    SharedViews.SoftEmptyState(
                        title: "No results",
                        systemImage: "magnifyingglass",
                        style: .puzzles,
                        description: "Try another puzzle name or brand."
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(filteredPuzzles, id: \.objectID) { puzzle in
                    NavigationLink {
                        PuzzleDetailView(puzzle: puzzle, household: household, member: member)
                    } label: {
                        PuzzleRow(puzzle: puzzle)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppCategoryStyle.puzzles.gradient.opacity(0.10))
        .navigationTitle("Puzzles")
        .searchable(text: $searchText, prompt: "Search by name or brand")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAddPuzzle = true
                } label: {
                    Label("Add Puzzle", systemImage: "plus")
                }
                .disabled(!canWrite)
            }
        }
        .sheet(isPresented: $showingAddPuzzle) {
            NavigationStack {
                AddEditPuzzleView(household: household)
            }
        }
    }
}

private struct PuzzleRow: View {
    let puzzle: LLPuzzle

    private var completedDateText: String {
        guard let completedAt = puzzle.completedAt else { return "Unknown" }
        return completedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private var pieceCountText: String {
        let count = Int(puzzle.pieceCount)
        return count > 0 ? "\(count) pieces" : "Pieces not set"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PuzzleThumbnail(photoData: puzzle.photoData)
                .overlay(alignment: .bottomTrailing) {
                    SharedViews.AccentIconBadge(systemImage: "checkmark", style: .puzzles)
                        .offset(x: 5, y: 5)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(puzzle.name ?? "Untitled")
                    .font(.headline)
                    .lineLimit(1)

                if let brand = puzzle.brand, !brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(brand)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("Completed \(completedDateText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SharedViews.AccentPill(pieceCountText, systemImage: "puzzlepiece", style: .puzzles)
            }
            .padding(.vertical, 1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .subtleCategoryRowCard(style: .puzzles, horizontalPadding: 9, verticalPadding: 6)
    }
}

private struct PuzzleThumbnail: View {
    let photoData: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(AppCategoryStyle.puzzles.gradient.opacity(0.45))

            if let photoData,
               let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "puzzlepiece")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 50, height: 50)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppCategoryStyle.puzzles.accent.opacity(0.22), lineWidth: 0.75)
        )
        .clipped()
    }
}
