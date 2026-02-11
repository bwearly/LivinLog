import SwiftUI
import CoreData
import UIKit

struct PuzzlesListView: View {
    let household: Household
    let member: HouseholdMember?

    @FetchRequest private var puzzles: FetchedResults<LLPuzzle>

    @State private var showingAddPuzzle = false
    @State private var searchText = ""

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
                    ContentUnavailableView {
                        Label("No puzzles yet", systemImage: "puzzlepiece")
                    } description: {
                        Text("Add your first puzzle")
                    } actions: {
                        Button("Add Puzzle") {
                            showingAddPuzzle = true
                        }
                    }
                } else {
                    ContentUnavailableView("No results", systemImage: "magnifyingglass")
                }
            } else {
                ForEach(filteredPuzzles, id: \.objectID) { puzzle in
                    NavigationLink {
                        PuzzleDetailView(puzzle: puzzle, household: household, member: member)
                    } label: {
                        PuzzleRow(puzzle: puzzle)
                    }
                }
            }
        }
        .navigationTitle("Puzzles")
        .searchable(text: $searchText, prompt: "Search by name or brand")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAddPuzzle = true
                } label: {
                    Label("Add Puzzle", systemImage: "plus")
                }
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
        HStack(alignment: .top, spacing: 12) {
            PuzzleThumbnail(photoData: puzzle.photoData)

            VStack(alignment: .leading, spacing: 6) {
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

                Text(pieceCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .padding(.vertical, 4)
    }
}

private struct PuzzleThumbnail: View {
    let photoData: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))

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
        .frame(width: 58, height: 58)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 0.5)
        )
        .clipped()
    }
}
