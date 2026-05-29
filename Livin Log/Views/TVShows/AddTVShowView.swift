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
    @EnvironmentObject private var appState: AppState

    let household: Household
    let member: HouseholdMember?

    @State private var title: String = ""
    @State private var yearText: String = ""
    @State private var contentRating: ContentRating = .unrated
    @State private var seasonsText: String = ""
    @State private var notes: String = ""
    @State private var rewatch: Bool = false
    @State private var selectedPosterURLString: String = ""
    @State private var selectedIMDbID: String?
    @State private var selectedMediaType: String?

    @State private var searchResults: [OMDbSearchResult] = []
    @State private var isSearchingMedia = false
    @State private var searchMessage: String?
    @State private var searchError: String?
    @FocusState private var focusedMediaField: MediaAutocompleteField?

    private enum MediaAutocompleteField: String {
        case title
        case year
    }

    private var isMediaAutocompleteFocused: Bool {
        focusedMediaField == .title || focusedMediaField == .year
    }

    private var shouldShowMediaAutocomplete: Bool {
        isMediaAutocompleteFocused && !searchResults.isEmpty
    }

    @State private var isSaving = false
    @State private var saveError: String?

    private let persistentContainer = PersistenceController.shared.container
    private var canWrite: Bool {
        IdentityStore.canAct(as: member, appUser: appState.appUser, context: context)
    }

    var body: some View {
        Form {
            Section("TV Show") {
                TextField("Title", text: $title)
                    .focused($focusedMediaField, equals: .title)

                TextField("Year", text: $yearText)
                    .keyboardType(.numberPad)
                    .focused($focusedMediaField, equals: .year)

                if isMediaAutocompleteFocused {
                    if isSearchingMedia {
                        ProgressView("Searching OMDb…")
                            .font(.caption)
                    } else if let searchError {
                        Text(searchError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let searchMessage {
                        Text(searchMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if shouldShowMediaAutocomplete {
                Section("TV Show Search Results") {
                    ForEach(searchResults) { result in
                        Button {
                            applySearchResult(result)
                        } label: {
                            MediaSearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Details") {
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
        .task(id: "\(title)|\(yearText)|\(focusedMediaField?.rawValue ?? "none")") {
            await searchTVShowsDebounced()
        }
        .onChange(of: focusedMediaField) { _, newFocus in
            if newFocus == nil {
                hideMediaAutocomplete()
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") {
                    Task { await saveTVShow() }
                }
                .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canWrite)
            }
        }
        .alert("Could Not Save TV Show", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "The TV show could not be saved.")
        }
    }


    private func searchTVShowsDebounced() async {
        guard isMediaAutocompleteFocused else {
            hideMediaAutocomplete()
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OMDbSearchService.meaningfulCharacterCount(in: trimmedTitle) >= 3 else {
            searchResults = []
            searchError = nil
            searchMessage = trimmedTitle.isEmpty ? nil : "Type at least 3 characters to search OMDb."
            isSearchingMedia = false
            return
        }

        do {
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled, isMediaAutocompleteFocused else { return }

        isSearchingMedia = true
        searchMessage = nil
        searchError = nil

        do {
            let results = try await OMDbSearchService.search(title: trimmedTitle, year: yearText, preferredType: .series)
            guard !Task.isCancelled, isMediaAutocompleteFocused else { return }
            searchResults = results
            searchMessage = results.isEmpty ? "No OMDb matches yet. You can still save manually." : nil
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
            searchMessage = nil
            searchError = "TV show search is temporarily unavailable. You can still enter details manually."
#if DEBUG
            print("📺 [TVShowSearch] active search failed: \(error)")
#endif
        }

        isSearchingMedia = false
    }

    private func applySearchResult(_ result: OMDbSearchResult) {
        title = result.title
        if let year = result.yearInt16 {
            yearText = String(Int(year))
        }
        selectedPosterURLString = result.normalizedPosterURLString
        selectedIMDbID = result.imdbID
        selectedMediaType = result.type
        hideMediaAutocomplete()
        focusedMediaField = nil
    }

    private func hideMediaAutocomplete() {
        searchResults = []
        searchMessage = nil
        searchError = nil
        isSearchingMedia = false
    }

#if DEBUG
    private static func tvShowCount(in household: Household, context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<TVShow>(entityName: "TVShow")
        request.predicate = householdScopedPredicate(household)
        request.includesPendingChanges = true
        do {
            return try context.count(for: request)
        } catch {
            print("❌ [TVShowSave] count failed: \(error.localizedDescription)")
            return -1
        }
    }
#endif

    @MainActor
    private func saveTVShow() async {
        guard !isSaving else { return }
        saveError = nil
        guard canWrite else {
            saveError = "You can add TV shows only from your own claimed member profile."
            return
        }
        isSaving = true
        defer { isSaving = false }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
            saveError = "Could not resolve the active household."
            return
        }

        // Ensure household has an id before linking
        if scopedHousehold.id == nil {
            scopedHousehold.id = UUID()
        }

        let tvShow = TVShow(context: context)
        do {
            try TVShowStoreSafety.assignInserted(tvShow, toSameStoreAs: scopedHousehold, context: context)
        } catch {
            context.rollback()
            saveError = error.localizedDescription
            return
        }
        tvShow.id = UUID()
        tvShow.createdAt = Date()
        tvShow.title = trimmedTitle
#if DEBUG
        let debugObjectIDBeforeSave = tvShow.objectID.uriRepresentation().absoluteString
        print("📺 [TVShowSave] title=\(trimmedTitle) objectIDBeforeSave=\(debugObjectIDBeforeSave) isInserted=\(tvShow.isInserted)")
        print("📺 [TVShowSave] household name=\(scopedHousehold.name ?? "<unnamed>") id=\(scopedHousehold.id?.uuidString ?? "<nil>") objectID=\(scopedHousehold.objectID.uriRepresentation().absoluteString) store=\(storeDebugDescription(scopedHousehold.objectID.persistentStore))")
        print("📺 [TVShowSave] tvShow store after assignment=\(storeDebugDescription(tvShow.objectID.persistentStore))")
#endif
        tvShow.household = scopedHousehold
        tvShow.householdID = scopedHousehold.id

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
        tvShow.posterURL = selectedPosterURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : selectedPosterURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        tvShow.setValue(selectedIMDbID, forKey: "imdbID")
        tvShow.setValue(selectedMediaType, forKey: "mediaType")

        // Store rating as text (Core Data: TVShow.ratingText : String)
        tvShow.ratingText = contentRating.rawValue

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        tvShow.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        // ✅ Fetch poster and store it on TVShow.posterURL (Core Data: String)
        if (tvShow.posterURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fetched = await OMDbPosterService.posterURL(title: tvShow.title, year: tvShow.year)
            tvShow.posterURL = fetched?.absoluteString
        }

        do {
            let objectsToValidate: [(String, NSManagedObject?)] = [("tvShow", tvShow), ("household", scopedHousehold)]
            context.debugLogStoreSafeSave(entityName: "TVShow", household: scopedHousehold, member: member, objects: objectsToValidate)
            try context.validateSamePersistentStore(objectsToValidate)
            try TVShowStoreSafety.validateGraph(tvShow: tvShow, context: context, operation: "TVShow.add", assignedBeforeRelationships: true)
            try context.save()
            print("ℹ️ TVShow inherits household share via parent household relationship (no per-object share mutation)")
#if DEBUG
            let totalAfterSave = Self.tvShowCount(in: scopedHousehold, context: context)
            print("📺 [TVShowSave] title=\(tvShow.title ?? "<untitled>") year=\(Int(tvShow.year)) objectIDBeforeSave=\(debugObjectIDBeforeSave) objectIDAfterSave=\(tvShow.objectID.uriRepresentation().absoluteString) isInserted=\(tvShow.isInserted)")
            print("📺 [TVShowSave] household name=\(scopedHousehold.name ?? "<unnamed>") id=\(scopedHousehold.id?.uuidString ?? "<nil>") store=\(storeDebugDescription(scopedHousehold.objectID.persistentStore)) totalTVShowsForHousehold=\(totalAfterSave)")
            debugPrintHouseholdDiagnostics(household: scopedHousehold, context: context, reason: "save")
            debugLogHouseholdAssignment(entityName: "TVShow", object: tvShow, household: scopedHousehold, context: context)
#endif
            dismiss()
        } catch {
            context.rollback()
            saveError = "Could not save TV show: \(error.localizedDescription)"
            print("Save TV show failed:", error)
        }
    }
}
