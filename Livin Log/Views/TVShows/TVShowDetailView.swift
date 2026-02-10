//
//  TVShowDetailView.swift
//  Keeply
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI
import CoreData

struct TVShowDetailView: View {
    @Environment(\.managedObjectContext) private var context

    let tvShow: TVShow
    let household: Household
    let member: HouseholdMember?

    @State private var isEditing = false

    @State private var editTitle: String = ""
    @State private var editYearText: String = ""
    @State private var editRating: Double = 0.0
    @State private var editSeasonsText: String = ""
    @State private var editNotes: String = ""
    @State private var editRewatch: Bool = false

    var body: some View {
        Form {
            headerSection
            detailsSection
        }
        .navigationTitle("TV Show")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(trailing:
            Button(isEditing ? "Save" : "Edit") {
                if isEditing {
                    saveDetails()
                    isEditing = false
                } else {
                    seedEditorFieldsFromShow()
                    isEditing = true
                }
            }
        )
        .onAppear {
            seedEditorFieldsFromShow()
        }
    }

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "tv")
                    .font(.largeTitle)
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text(isEditing ? editTitle : (tvShow.title ?? "—"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text(tvShow.year == 0 ? "—" : String(tvShow.year))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            if isEditing {
                TextField("Title", text: $editTitle)

                TextField("Year", text: $editYearText)
                    .keyboardType(.numberPad)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Rating")
                        Spacer()
                        Text(ratingText(editRating))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(value: $editRating, in: 0...10, step: 0.25)
                }
                .padding(.vertical, 4)

                TextField("Seasons", text: $editSeasonsText)
                    .keyboardType(.numberPad)

                Toggle("Rewatch", isOn: $editRewatch)

                TextEditor(text: $editNotes)
                    .frame(minHeight: 90)
            } else {
                row("Rating", ratingText(tvShow.rating))
                row("Seasons", tvShow.seasons == 0 ? "—" : "\(tvShow.seasons)")
                row("Rewatch", tvShow.rewatch ? "Yes" : "No")

                if let notes = tvShow.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes")
                        Text(notes)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func ratingText(_ value: Double) -> String {
        if value == 0 { return "0/10" }
        return String(format: "%.2f/10", value)
    }

    private func seedEditorFieldsFromShow() {
        editTitle = tvShow.title ?? ""
        editYearText = tvShow.year == 0 ? "" : String(tvShow.year)
        editRating = tvShow.rating
        editSeasonsText = tvShow.seasons == 0 ? "" : String(tvShow.seasons)
        editNotes = tvShow.notes ?? ""
        editRewatch = tvShow.rewatch
    }

    private func saveDetails() {
        tvShow.title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if let y = Int16(editYearText.trimmingCharacters(in: .whitespacesAndNewlines)), y > 0 {
            tvShow.year = y
        } else {
            tvShow.year = 0
        }

        if let s = Int16(editSeasonsText.trimmingCharacters(in: .whitespacesAndNewlines)), s > 0 {
            tvShow.seasons = s
        } else {
            tvShow.seasons = 0
        }

        tvShow.rating = editRating
        tvShow.rewatch = editRewatch

        let trimmedNotes = editNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        tvShow.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        do {
            try context.save()
        } catch {
            context.rollback()
            print("Save TV show failed:", error)
        }
    }
}
