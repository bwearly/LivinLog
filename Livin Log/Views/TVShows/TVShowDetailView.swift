//
//  TVShowDetailView.swift
//  Livin Log
//
//  Created by Blake Early on 1/12/26.
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
    @State private var editRating: ContentRating = .unrated
    @State private var editSeasonsText: String = ""
    @State private var editNotes: String = ""
    @State private var editRewatch: Bool = false

    // Poster
    @State private var posterURL: URL?

    private let persistentContainer = PersistenceController.shared.container

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
            seedPosterFromStoredURL()
        }
        .task {
            await ensurePosterLoaded()
        }
    }

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                TVPosterLarge(posterURL: $posterURL)

                VStack(alignment: .leading, spacing: 6) {
                    Text(isEditing ? editTitle : (tvShow.title ?? "—"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text(tvShow.year == 0 ? "—" : String(Int(tvShow.year)))
                        .foregroundStyle(.secondary)

                    let r = (tvShow.ratingText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !r.isEmpty {
                        Text(r)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
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

                Picker("Rating", selection: $editRating) {
                    ForEach(ContentRating.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }

                TextField("Seasons", text: $editSeasonsText)
                    .keyboardType(.numberPad)

                Toggle("Rewatch", isOn: $editRewatch)

                TextEditor(text: $editNotes)
                    .frame(minHeight: 90)
            } else {
                row("Rating", (tvShow.ratingText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? (tvShow.ratingText ?? "—") : "—")
                row("Seasons", tvShow.seasons == 0 ? "—" : "\(Int(tvShow.seasons))")
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

    private func seedEditorFieldsFromShow() {
        editTitle = tvShow.title ?? ""
        editYearText = tvShow.year == 0 ? "" : String(Int(tvShow.year))
        editSeasonsText = tvShow.seasons == 0 ? "" : String(Int(tvShow.seasons))
        editNotes = tvShow.notes ?? ""
        editRewatch = tvShow.rewatch

        // ratingText is stored as String on TVShow
        if let stored = tvShow.ratingText,
           let parsed = ContentRating(rawValue: stored) {
            editRating = parsed
        } else {
            editRating = .unrated
        }
    }

    private func saveDetails() {
        let newTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else { return }
        guard let tvShowInContext = (try? context.existingObject(with: tvShow.objectID)) as? TVShow else { return }
        let oldTitle = tvShowInContext.title ?? ""
        let oldYear = tvShowInContext.year
        let store = storeForParent(tvShowInContext)
#if DEBUG
        print("🧩 [EditSave] entity=TVShow store=\(store?.url?.lastPathComponent ?? "nil-store") objectID=\(tvShowInContext.objectID.uriRepresentation().absoluteString)")
#endif

        tvShowInContext.title = newTitle

        if let y = Int16(editYearText.trimmingCharacters(in: .whitespacesAndNewlines)), y > 0 {
            tvShowInContext.year = y
        } else {
            tvShowInContext.year = 0
        }

        if let s = Int16(editSeasonsText.trimmingCharacters(in: .whitespacesAndNewlines)), s > 0 {
            tvShowInContext.seasons = s
        } else {
            tvShowInContext.seasons = 0
        }

        tvShowInContext.rewatch = editRewatch
        tvShowInContext.ratingText = editRating.rawValue
        assignIfInserted(tvShowInContext, to: store, in: context)
        tvShowInContext.household = scopedHousehold
        tvShowInContext.householdID = scopedHousehold.id

        let trimmedNotes = editNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        tvShowInContext.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        do {
            try context.save()
            print("ℹ️ TVShow inherits household share via parent household relationship (no per-object share mutation)")
#if DEBUG
            debugLogHouseholdAssignment(entityName: "TVShow", object: tvShowInContext, household: scopedHousehold, context: context)
#endif
        } catch {
            context.rollback()
            print("Save TV show failed:", error)
            return
        }

        // If title/year changed, refresh poster (same behavior as MovieDetailView)
        let titleChanged = newTitle != oldTitle
        let yearChanged = tvShowInContext.year != oldYear
        if titleChanged || yearChanged {
            Task { await refreshPoster() }
        }
    }

    // MARK: - Poster helpers

    private func seedPosterFromStoredURL() {
        let s = (tvShow.posterURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let url = URL(string: s) else {
            posterURL = nil
            return
        }
        posterURL = url
    }

    private func ensurePosterLoaded() async {
        // Use stored first
        let stored = (tvShow.posterURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty, let url = URL(string: stored) {
            await MainActor.run { posterURL = url }
            return
        }

        // Fetch + persist
        let fetched = await OMDbPosterService.posterURL(title: tvShow.title, year: tvShow.year)
        guard let fetched else { return }

        await MainActor.run {
            tvShow.posterURL = fetched.absoluteString
            posterURL = fetched
            try? context.save()
        }
    }

    private func refreshPoster() async {
        let fetched = await OMDbPosterService.posterURL(title: tvShow.title, year: tvShow.year)

        await MainActor.run {
            tvShow.posterURL = fetched?.absoluteString
            posterURL = fetched
            try? context.save()
        }
    }
}

// MARK: - Poster Large (TV)

private struct TVPosterLarge: View {
    @Binding var posterURL: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))

            if let posterURL {
                AsyncImage(url: posterURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image(systemName: "tv")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "tv")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 90, height: 130)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}
