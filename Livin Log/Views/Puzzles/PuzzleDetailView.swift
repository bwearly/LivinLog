import SwiftUI
import CoreData
import UIKit

struct PuzzleDetailView: View {
    let puzzle: LLPuzzle
    let household: Household
    let member: HouseholdMember?

    @State private var showingEdit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PuzzleHeroImage(photoData: puzzle.photoData)

                VStack(alignment: .leading, spacing: 10) {
                    Text(puzzle.name ?? "Untitled")
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let brand = puzzle.brand, !brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        detailRow("Brand", value: brand)
                    }

                    detailRow("Piece Count", value: pieceCountText)
                    detailRow("Completed", value: completedDateText)

                    if let createdAt = puzzle.createdAt {
                        detailRow("Added", value: createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.thinMaterial)
                )

                if let notes = puzzle.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Memory")
                            .font(.headline)
                        Text(notes)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.thinMaterial)
                    )
                }
            }
            .padding(16)
        }
        .navigationTitle("Puzzle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") {
                    showingEdit = true
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                AddEditPuzzleView(household: household, editingPuzzle: puzzle)
            }
        }
    }

    private var completedDateText: String {
        guard let completedAt = puzzle.completedAt else { return "—" }
        return completedAt.formatted(date: .complete, time: .omitted)
    }

    private var pieceCountText: String {
        let count = Int(puzzle.pieceCount)
        return count > 0 ? "\(count) pieces" : "Not set"
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}

private struct PuzzleHeroImage: View {
    let photoData: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial)

            if let photoData,
               let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece")
                        .font(.largeTitle)
                    Text("No photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        )
        .clipped()
    }
}
