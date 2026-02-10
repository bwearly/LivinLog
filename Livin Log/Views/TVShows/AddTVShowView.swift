//
//  AddTVShowView.swift
//  Livin Log
//
//  Created by Blake Early on 1/12/26.
//

import SwiftUI
import CoreData

struct AddTVShowView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    let household: Household
    let member: HouseholdMember?

    @State private var title: String = ""
    @State private var yearText: String = ""
    @State private var contentRating: ContentRating = .unrated
    @State private var seasonsText: String = ""
    @State private var notes: String = ""
    @State private var rewatch: Bool = false

    @State private var isSaving = false

    var body: some View {
        Form {
            Section("TV Show") {
                TextField("Title", text: $title)

                TextField("Year", text: $yearText)
                    .keyboardType(.numberPad)

                Picker("Rating", selection: $contentRating) {
                    ForEach(ContentRating.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }

                TextField("Seasons", text: $seasonsText)
                    .keyboardType(.numberPad)

                Toggle("Rewatch", isOn: $rewatch)

                TextEditor(text: $notes)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Notes (optional)")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                    }
            }
        }
        .navigationTitle("Add TV Show")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") {
                    Task { await saveTVShow() }
                }
                .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @MainActor
    private func saveTVShow() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ensure household has an id before linking
        if household.id == nil {
            household.id = UUID()
            try? context.save()
        }

        let tvShow = TVShow(context: context)
        tvShow.id = UUID()
        tvShow.createdAt = Date()
        tvShow.title = trimmedTitle
        tvShow.household = household
        tvShow.householdID = household.id

        if let y = Int16(yearText.trimmingCharacters(in: .whitespacesAndNewlines)), y > 0 {
            tvShow.year = y
        } else {
            tvShow.year = 0
        }

        if let s = Int16(seasonsText.trimmingCharacters(in: .whitespacesAndNewlines)), s > 0 {
            tvShow.seasons = s
        } else {
            tvShow.seasons = 0
        }

        tvShow.rewatch = rewatch

        // Store rating as text (Core Data: TVShow.ratingText : String)
        tvShow.ratingText = contentRating.rawValue

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        tvShow.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        // ✅ Fetch poster and store it on TVShow.posterURL (Core Data: String)
        let fetched = await OMDbPosterService.posterURL(title: tvShow.title, year: tvShow.year)
        tvShow.posterURL = fetched?.absoluteString

        do {
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            print("Save TV show failed:", error)
        }
    }
}
