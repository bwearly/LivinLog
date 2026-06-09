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
    @EnvironmentObject private var appState: AppState

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
    @State private var editSelectedPosterURLString: String = ""
    @State private var editSelectedIMDbID: String?
    @State private var editSelectedMediaType: String?

    @State private var editSearchResults: [OMDbSearchResult] = []
    @State private var isSearchingEditMedia = false
    @State private var editSearchMessage: String?
    @State private var editSearchError: String?
    @FocusState private var focusedEditMediaField: EditMediaAutocompleteField?

    private enum EditMediaAutocompleteField: String {
        case title
        case year
    }

    private var isEditMediaAutocompleteFocused: Bool {
        focusedEditMediaField == .title || focusedEditMediaField == .year
    }

    private var shouldShowEditMediaAutocomplete: Bool {
        isEditing && isEditMediaAutocompleteFocused && !editSearchResults.isEmpty
    }

    // Poster
    @State private var posterURL: URL?
    @State private var saveError: String?

    private let persistentContainer = PersistenceController.shared.container
    private var canWrite: Bool {
        IdentityStore.canAct(as: member, appUser: appState.appUser, context: context)
    }

    var body: some View {
        Form {
            headerSection
            detailsSection
        }
        .navigationTitle("TV Show")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(
            leading: Group {
                if isEditing {
                    Button("Cancel") { cancelEditing() }
                }
            },
            trailing: Button(isEditing ? "Save" : "Edit") {
                guard canWrite else { return }
                if isEditing {
                    if saveDetails() {
                        isEditing = false
                    }
                } else {
                    beginEditing()
                }
            }
            .disabled(!canWrite)
        )
        .task(id: "\(isEditing)|\(editTitle)|\(editYearText)|\(focusedEditMediaField?.rawValue ?? "none")") {
            await searchEditTVShowsDebounced()
        }
        .onChange(of: focusedEditMediaField) { _, newFocus in
            if newFocus == nil {
                hideEditMediaAutocomplete()
            }
        }
        .onAppear {
            seedEditorFieldsFromShow()
            seedPosterFromStoredURL()
        }
        .task {
            await ensurePosterLoaded()
        }
        .alert("Could Not Save TV Show", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "The TV show could not be saved.")
        }
    }


    private func searchEditTVShowsDebounced() async {
        guard isEditing, isEditMediaAutocompleteFocused else {
            hideEditMediaAutocomplete()
            return
        }

        let trimmedTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OMDbSearchService.meaningfulCharacterCount(in: trimmedTitle) >= 3 else {
            editSearchResults = []
            editSearchError = nil
            editSearchMessage = trimmedTitle.isEmpty ? nil : "Type at least 3 characters to search OMDb."
            isSearchingEditMedia = false
            return
        }

        do {
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled, isEditing, isEditMediaAutocompleteFocused else { return }

        isSearchingEditMedia = true
        editSearchMessage = nil
        editSearchError = nil

        do {
            let results = try await OMDbSearchService.search(title: trimmedTitle, year: editYearText, preferredType: .series)
            guard !Task.isCancelled, isEditing, isEditMediaAutocompleteFocused else { return }
            editSearchResults = results
            editSearchMessage = results.isEmpty ? "No OMDb matches yet. You can still save manually." : nil
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            editSearchResults = []
            editSearchMessage = nil
            editSearchError = "TV show search is temporarily unavailable. You can still enter details manually."
#if DEBUG
            print("📺 [TVShowEditSearch] active search failed: \(error)")
#endif
        }

        isSearchingEditMedia = false
    }

    private func applyEditSearchResult(_ result: OMDbSearchResult) {
        editTitle = result.title
        if let year = result.yearInt16 {
            editYearText = String(Int(year))
        }
        editSelectedPosterURLString = result.normalizedPosterURLString
        editSelectedIMDbID = result.imdbID
        editSelectedMediaType = result.type
        posterURL = result.posterURL
        hideEditMediaAutocomplete()
        focusedEditMediaField = nil
    }

    private func hideEditMediaAutocomplete() {
        editSearchResults = []
        editSearchMessage = nil
        editSearchError = nil
        isSearchingEditMedia = false
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
                    .focused($focusedEditMediaField, equals: .title)

                TextField("Year", text: $editYearText)
                    .keyboardType(.numberPad)
                    .focused($focusedEditMediaField, equals: .year)

                if isEditMediaAutocompleteFocused {
                    if isSearchingEditMedia {
                        ProgressView("Searching OMDb…")
                            .font(.caption)
                    } else if let editSearchError {
                        Text(editSearchError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let editSearchMessage {
                        Text(editSearchMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if shouldShowEditMediaAutocomplete {
                    ForEach(editSearchResults) { result in
                        Button {
                            applyEditSearchResult(result)
                        } label: {
                            MediaSearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                    }
                }

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

    private func beginEditing() {
        seedEditorFieldsFromShow()
        hideEditMediaAutocomplete()
        isEditing = true
    }

    private func cancelEditing() {
        context.rollback()
        seedEditorFieldsFromShow()
        seedPosterFromStoredURL()
        hideEditMediaAutocomplete()
        focusedEditMediaField = nil
        isEditing = false
    }

    private func seedEditorFieldsFromShow() {
        editTitle = tvShow.title ?? ""
        editYearText = tvShow.year == 0 ? "" : String(Int(tvShow.year))
        editSeasonsText = tvShow.seasons == 0 ? "" : String(Int(tvShow.seasons))
        editNotes = tvShow.notes ?? ""
        editRewatch = tvShow.rewatch
        editSelectedPosterURLString = tvShow.posterURL ?? ""
        editSelectedIMDbID = tvShow.value(forKey: "imdbID") as? String
        editSelectedMediaType = tvShow.value(forKey: "mediaType") as? String

        // ratingText is stored as String on TVShow
        if let stored = tvShow.ratingText,
           let parsed = ContentRating(rawValue: stored) {
            editRating = parsed
        } else {
            editRating = .unrated
        }
    }

    private func saveDetails() -> Bool {
        guard canWrite else { return false }
        saveError = nil
        let newTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let tvShowInContext = (try? context.existingObject(with: tvShow.objectID)) as? TVShow else {
            saveError = "Could not resolve this TV show in the current context."
            return false
        }
        guard let scopedHousehold = tvShowInContext.household else {
            saveError = "This TV show is not linked to a household. Nothing was saved."
            return false
        }

        do {
            try TVShowStoreSafety.validateActiveHouseholdIfPresent(activeHouseholdInContext(household, context: context), matchesDerivedHousehold: scopedHousehold, context: context)
            try TVShowStoreSafety.validateGraph(tvShow: tvShowInContext, context: context, operation: "TVShow.edit.preflight")
        } catch {
            context.rollback()
            saveError = error.localizedDescription
            print("❌ [TVShowEdit] preflight blocked:", error)
            return false
        }

        let oldTitle = tvShowInContext.title ?? ""
        let oldYear = tvShowInContext.year
#if DEBUG
        let store = storeForParent(tvShowInContext)
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
        let selectedPoster = editSelectedPosterURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedPoster.isEmpty {
            tvShowInContext.posterURL = selectedPoster
            posterURL = URL(string: selectedPoster)
        }
        tvShowInContext.setValue(editSelectedIMDbID, forKey: "imdbID")
        tvShowInContext.setValue(editSelectedMediaType, forKey: "mediaType")
        tvShowInContext.ratingText = editRating.rawValue
        if scopedHousehold.id == nil {
            scopedHousehold.id = UUID()
        }
        tvShowInContext.householdID = scopedHousehold.id

        let trimmedNotes = editNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        tvShowInContext.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        do {
            let objectsToValidate: [(String, NSManagedObject?)] = [("tvShow", tvShowInContext), ("household", scopedHousehold)]
            context.debugLogStoreSafeSave(entityName: "TVShow", household: scopedHousehold, member: member, objects: objectsToValidate)
            try context.validateSamePersistentStore(objectsToValidate)
            try TVShowStoreSafety.validateGraph(tvShow: tvShowInContext, context: context, operation: "TVShow.edit")
            try context.save()
            print("ℹ️ TVShow inherits household share via parent household relationship (no per-object share mutation)")
#if DEBUG
            debugLogHouseholdAssignment(entityName: "TVShow", object: tvShowInContext, household: scopedHousehold, context: context)
#endif
        } catch {
            context.rollback()
            saveError = "Could not save TV show: \(error.localizedDescription)"
            print("Save TV show failed:", error)
            return false
        }

        // If title/year changed, refresh poster (same behavior as MovieDetailView)
        let titleChanged = newTitle != oldTitle
        let yearChanged = tvShowInContext.year != oldYear
        if titleChanged || yearChanged {
            let objectID = tvShowInContext.objectID
            Task { await refreshPoster(for: objectID) }
        }
        return true
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
        let snapshot: (NSManagedObjectID, String?, Int16, String?)? = await MainActor.run {
            guard let tvShowInContext = (try? context.existingObject(with: tvShow.objectID)) as? TVShow else { return nil }
            return (tvShowInContext.objectID, tvShowInContext.title, tvShowInContext.year, tvShowInContext.posterURL)
        }
        guard let snapshot else { return }

        let stored = (snapshot.3 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty, let url = URL(string: stored) {
            await MainActor.run { posterURL = url }
            return
        }

        let fetched = await OMDbPosterService.posterURL(title: snapshot.1, year: snapshot.2)
        guard let fetched else { return }

        await savePoster(fetched, for: snapshot.0, operation: "TVShow.poster.ensure")
    }

    private func refreshPoster(for objectID: NSManagedObjectID) async {
        let snapshot: (String?, Int16)? = await MainActor.run {
            guard let tvShowInContext = (try? context.existingObject(with: objectID)) as? TVShow else { return nil }
            return (tvShowInContext.title, tvShowInContext.year)
        }
        guard let snapshot else { return }

        let fetched = await OMDbPosterService.posterURL(title: snapshot.0, year: snapshot.1)
        await savePoster(fetched, for: objectID, operation: "TVShow.poster.refresh")
    }

    @MainActor
    private func savePoster(_ fetched: URL?, for objectID: NSManagedObjectID, operation: String) {
        guard let tvShowInContext = (try? context.existingObject(with: objectID)) as? TVShow else { return }
        tvShowInContext.posterURL = fetched?.absoluteString
        posterURL = fetched
        do {
            try TVShowStoreSafety.validateGraph(tvShow: tvShowInContext, context: context, operation: operation)
            try context.save()
        } catch {
            context.rollback()
            saveError = "Could not save the TV show poster: \(error.localizedDescription)"
            print("❌ [TVShowPoster] save blocked:", error)
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
