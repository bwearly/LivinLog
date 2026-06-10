//
//  AddMovieView.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI
import CoreData

struct AddMovieView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let household: Household
    let member: HouseholdMember?

    // Movie fields
    @State private var title: String = ""
    @State private var yearText: String = ""
    @State private var mpaaRating: String = "—"
    @State private var notes: String = ""
    @State private var watchedOn: Date = Date()
    @State private var selectedPosterURLString: String = ""
    @State private var selectedIMDbID: String?
    @State private var selectedMediaType: String?
    @State private var hasSelectedMediaResult = false

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

    // Genres
    @State private var selectedGenres: Set<String> = []
    @State private var showGenrePicker = false

    // Feedback drafts
    @State private var feedbackByMemberID: [NSManagedObjectID: MemberFeedbackDraft] = [:]
    @State private var saveError: String?

    private let persistentContainer = PersistenceController.shared.container

    private let mpaaOptions: [String] = ["—", "G", "PG", "PG-13", "R", "NC-17", "Not Rated"]
    private let allGenres: [String] = [
        "Action","Adventure","Animation","Biography","Comedy","Crime","Documentary","Drama","Family",
        "Fantasy","Film-Noir","History","Horror","Music","Musical","Mystery","Romance","Sci-Fi",
        "Short","Sport","Thriller","War","Western"
    ]

    var body: some View {
        Form {
            Section {
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
            } header: {
                SharedViews.AccentSectionHeader(title: "Movie", systemImage: "film.fill", style: .movies)
            }

            if shouldShowMediaAutocomplete {
                Section {
                    ForEach(searchResults) { result in
                        Button {
                            Task { await applySearchResult(result) }
                        } label: {
                            MediaSearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    SharedViews.AccentSectionHeader(title: "Movie Search Results", systemImage: "magnifyingglass", style: .movies)
                }
            }

            if hasSelectedMediaResult {
                Section {
                    SelectedMediaPosterPreview(
                        title: title.isEmpty ? "Selected movie" : title,
                        subtitle: yearText.isEmpty ? "Movie" : "Movie • \(yearText)",
                        posterURLString: selectedPosterURLString,
                        systemImage: "film.fill",
                        style: .movies
                    )
                }
            }

            Section {
                DatePicker(
                    "Watch date",
                    selection: $watchedOn,
                    in: ...Date(),
                    displayedComponents: .date
                )

                Picker("MPAA Rating", selection: $mpaaRating) {
                    ForEach(mpaaOptions, id: \.self) { r in
                        Text(r).tag(r)
                    }
                }

                Button { showGenrePicker = true } label: {
                    HStack {
                        Text("Genres")
                        Spacer()
                        Text(genresDisplay)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

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
            } header: {
                SharedViews.AccentSectionHeader(title: "Details", systemImage: "slider.horizontal.3", style: .movies)
            }

            Section {
                if actingMember != nil {
                    ForEach(householdMembersForFeedback) { m in
                        let draft = bindingForMember(m)

                        DisclosureGroup {
                            VStack(spacing: 0) {

                                // Rating row
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("Rating")
                                        Spacer()
                                        Text(ratingText(draft.wrappedValue.rating))
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }

                                    Slider(value: draft.rating, in: 0...10, step: 0.25)
                                }
                                .padding(.vertical, 10)

                                Divider()

                                // Slept row
                                HStack {
                                    Text("Fell asleep")
                                    Spacer()
                                    Toggle("", isOn: draft.slept)
                                        .labelsHidden()
                                }
                                .padding(.vertical, 10)

                                Divider()

                                // Notes row
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Notes")

                                    TextEditor(text: draft.notes)
                                        .frame(minHeight: 80)
                                        .overlay(alignment: .topLeading) {
                                            if draft.wrappedValue.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                Text("Optional")
                                                    .foregroundStyle(.secondary)
                                                    .padding(.top, 8)
                                                    .padding(.leading, 5)
                                            }
                                        }
                                }
                                .padding(.vertical, 10)
                            }
                        } label: {
                            HStack {
                                Text(m.displayName ?? "Member")
                                    .font(.headline)
                                Spacer()
                                Text(ratingText(draft.wrappedValue.rating))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                        }
                    }
                } else {
                    Text("Claim your member profile before adding a movie.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                SharedViews.AccentSectionHeader(title: "Household Feedback", systemImage: "star.bubble.fill", style: .movies)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppCategoryStyle.movies.gradient.opacity(0.18))
        .navigationTitle("Add Movie")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveMovie() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || actingMember == nil)
            }
        }
        .task(id: "\(title)|\(yearText)|\(focusedMediaField?.rawValue ?? "none")") {
            await searchMoviesDebounced()
        }
        .onChange(of: focusedMediaField) { _, newFocus in
            if newFocus == nil {
                hideMediaAutocomplete()
            }
        }
        .navigationDestination(isPresented: $showGenrePicker) {
            GenrePickerView(title: "Select Genres", allGenres: allGenres, selected: $selectedGenres)
        }
        .alert("Could Not Save Movie", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "The movie could not be saved.")
        }
        .onAppear {
            seedFeedbackDraftsIfNeeded()
        }
    }


    private func searchMoviesDebounced() async {
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
            let results = try await OMDbSearchService.search(title: trimmedTitle, year: yearText, preferredType: .movie)
            guard !Task.isCancelled, isMediaAutocompleteFocused else { return }
            searchResults = results
            searchMessage = results.isEmpty ? "No OMDb matches yet. You can still save manually." : nil
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
            searchMessage = nil
            searchError = "Movie search is temporarily unavailable. You can still enter details manually."
#if DEBUG
            print("🎬 [MovieSearch] active search failed: \(error)")
#endif
        }

        isSearchingMedia = false
    }

    @MainActor
    private func applySearchResult(_ result: OMDbSearchResult) async {
        let detailedResult = (try? await OMDbSearchService.details(for: result)) ?? result
        applyMetadata(from: detailedResult)
        hideMediaAutocomplete()
        focusedMediaField = nil
    }

    private func applyMetadata(from result: OMDbSearchResult) {
        title = result.title
        if let year = result.yearInt16 {
            yearText = String(Int(year))
        }
        selectedPosterURLString = result.normalizedPosterURLString
        selectedIMDbID = result.imdbID
        selectedMediaType = result.type
        if !result.genres.isEmpty {
            selectedGenres.formUnion(result.genres)
        }
        if let contentRating = result.contentRating, mpaaOptions.contains(contentRating) {
            mpaaRating = contentRating
        }
        hasSelectedMediaResult = true
    }

    private func hideMediaAutocomplete() {
        searchResults = []
        searchMessage = nil
        searchError = nil
        isSearchingMedia = false
    }

    // MARK: - Formatting

    private func ratingText(_ value: Double) -> String {
        if value == 0 { return "0/10" }
        return String(format: "%.2f/10", value)
    }

    private var genresDisplay: String {
        selectedGenres.isEmpty ? "—" : selectedGenres.sorted().joined(separator: ", ")
    }

    // MARK: - Members (fetch instead of relationship accessors)

    private var householdMembersForFeedback: [HouseholdMember] {
        fetchedMembers()
    }

    private func fetchedMembers() -> [HouseholdMember] {
        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else { return [] }
        let req = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        req.predicate = householdScopedPredicate(scopedHousehold)
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return (try? context.fetch(req)) ?? []
    }

    private var actingMember: HouseholdMember? {
        guard let member else { return nil }
        return IdentityStore.canAct(as: member, appUser: appState.appUser, context: context) ? member : nil
    }

    private func seedFeedbackDraftsIfNeeded() {
        for m in householdMembersForFeedback {
            if feedbackByMemberID[m.objectID] == nil {
                feedbackByMemberID[m.objectID] = MemberFeedbackDraft()
            }
        }
    }

    private func bindingForMember(_ m: HouseholdMember) -> Binding<MemberFeedbackDraft> {
        let id = m.objectID
        return Binding(
            get: { feedbackByMemberID[id] ?? MemberFeedbackDraft() },
            set: { feedbackByMemberID[id] = $0 }
        )
    }

    private func isDraftEmpty(_ d: MemberFeedbackDraft) -> Bool {
        d.rating == 0 &&
        d.slept == false &&
        d.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Save

    private func saveMovie() {
        saveError = nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let actingMember else {
            saveError = "Choose your member profile before saving a movie."
            return
        }
        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
            saveError = "Could not resolve the active household."
            return
        }

        let scopedActingMember: HouseholdMember
        do {
            guard let resolvedMember = try MovieStoreSafety.resolveMember(actingMember, in: scopedHousehold, context: context) else {
                saveError = "Could not resolve your member profile in this household store."
                return
            }
            scopedActingMember = resolvedMember
            try context.validateSamePersistentStore([("household", scopedHousehold), ("actingMember", scopedActingMember)])
        } catch {
            context.rollback()
            saveError = error.localizedDescription
            return
        }

        let movie = Movie(context: context)
        do {
            try MovieStoreSafety.assignInserted(movie, toSameStoreAs: scopedHousehold, label: "Movie(new)", context: context)
        } catch {
            context.rollback()
            saveError = error.localizedDescription
            return
        }
        movie.id = UUID()
        movie.createdAt = Date()
        movie.title = trimmedTitle

        movie.household = scopedHousehold
        
        // Ensure household has stable id
        if scopedHousehold.id == nil {
            scopedHousehold.id = UUID()
        }

        // ✅ Store householdID directly on Movie
        movie.householdID = scopedHousehold.id

        if let y = Int16(yearText.trimmingCharacters(in: .whitespacesAndNewlines)), y > 0 {
            movie.year = y
        } else {
            movie.year = 0
        }

        movie.mpaaRating = (mpaaRating == "—") ? nil : mpaaRating
        movie.genre = selectedGenres.isEmpty ? nil : selectedGenres.sorted().joined(separator: ", ")
        movie.posterURL = selectedPosterURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : selectedPosterURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        movie.setValue(selectedIMDbID, forKey: "imdbID")
        movie.setValue(selectedMediaType, forKey: "mediaType")

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        movie.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        // Feedback rows
        var createdFeedbacks: [MovieFeedback] = []
        for memberDraft in householdMembersForFeedback {
            guard let draft = feedbackByMemberID[memberDraft.objectID], !isDraftEmpty(draft) else { continue }

            let memberInContext: HouseholdMember
            do {
                guard let resolvedMember = try MovieStoreSafety.resolveMember(memberDraft, in: scopedHousehold, context: context) else {
                    saveError = "Could not resolve \(memberDraft.displayName ?? "the selected member") in this household."
                    context.rollback()
                    return
                }
                memberInContext = resolvedMember
                try context.validateSamePersistentStore([("movie", movie), ("household", scopedHousehold), ("member", memberInContext)])
            } catch {
                context.rollback()
                saveError = error.localizedDescription
                return
            }

            let fb: MovieFeedback
            do {
                fb = try MovieFeedbackStore.getOrCreate(movie: movie, member: memberInContext, context: context)
            } catch {
                context.rollback()
                saveError = error.localizedDescription
                return
            }
            fb.updatedAt = Date()
            fb.rating = draft.rating
            fb.slept = draft.slept

            let n = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            fb.notes = n.isEmpty ? nil : n
            fb.household = scopedHousehold
            createdFeedbacks.append(fb)
        }
        
        // ✅ Add initial watch history record on create
        let v = Viewing(context: context)
        do {
            try MovieStoreSafety.assignInserted(v, toSameStoreAs: scopedHousehold, label: "Viewing(new)", context: context)
        } catch {
            context.rollback()
            saveError = error.localizedDescription
            return
        }
        // awakeFromInsert already sets id + watchedOn
        v.isRewatch = false
        v.watchedOn = watchedOn
        v.notes = nil
        v.movie = movie
        v.household = scopedHousehold

        do {
            var objectsToValidate: [(String, NSManagedObject?)] = [
                ("movie", movie),
                ("household", scopedHousehold),
                ("viewing", v)
            ]
            for (index, feedback) in createdFeedbacks.enumerated() {
                objectsToValidate.append(("feedback[\(index)]", feedback))
                objectsToValidate.append(("feedback[\(index)].member", feedback.member))
            }
            context.debugLogViewingSave(operation: "Movie.add.initialViewing", viewing: v, movie: movie, household: scopedHousehold, member: scopedActingMember, assignedBeforeRelationships: true)
            context.debugLogStoreSafeSave(entityName: "Movie", household: scopedHousehold, member: scopedActingMember, objects: objectsToValidate)
            try context.validateSamePersistentStore(objectsToValidate)
            try MovieStoreSafety.validateViewingGraph(viewing: v, movie: movie, household: scopedHousehold, member: scopedActingMember, context: context, operation: "Movie.add.initialViewing", assignedBeforeRelationships: true)
            try context.save()
            print("🎬 [MovieSave] movie=\(movie.title ?? "<untitled>") movieID=\(movie.id?.uuidString ?? "<nil>") household=\(scopedHousehold.name ?? "<unnamed>") householdID=\(movie.householdID?.uuidString ?? "<nil>") viewingID=\(v.id?.uuidString ?? "<nil>") watchedOn=\(v.watchedOn?.description ?? "<nil>") member=\(scopedActingMember.displayName ?? "<nil>")")
            print("ℹ️ Movie inherits household share via parent household relationship (no per-object share mutation)")
            if !createdFeedbacks.isEmpty {
                print("ℹ️ MovieFeedback inherits household share via parent household relationship (no per-object share mutation)")
            }
            print("ℹ️ Viewing inherits household share via parent household relationship (no per-object share mutation)")
#if DEBUG
            debugPrintHouseholdDiagnostics(household: scopedHousehold, context: context, reason: "save")
            debugLogHouseholdAssignment(entityName: "Movie", object: movie, household: scopedHousehold, context: context)
            debugLogHouseholdAssignment(entityName: "Viewing", object: v, household: scopedHousehold, context: context)
            for fb in createdFeedbacks {
                debugLogHouseholdAssignment(entityName: "MovieFeedback", object: fb, household: scopedHousehold, context: context)
            }
#endif

            // ✅ Fetch + persist poster AFTER the movie is saved
            let movieObjectID = movie.objectID
            let posterTitle = movie.title
            let posterYear = movie.year
            Task {
                let url = await OMDbPosterService.posterURL(title: posterTitle, year: posterYear)
                let httpsURL = url.flatMap {
                    URL(string: $0.absoluteString.replacingOccurrences(of: "http://", with: "https://"))
                }

                await MainActor.run {
                    guard let movieInContext = (try? context.existingObject(with: movieObjectID)) as? Movie else { return }
                    if (movieInContext.posterURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        movieInContext.posterURL = httpsURL?.absoluteString
                    }
                    do {
                        try MovieStoreSafety.validateMovieGraph(movie: movieInContext, household: movieInContext.household, context: context, operation: "Movie.poster.add")
                        try context.save()
                    } catch {
                        context.rollback()
                        print("❌ [MoviePoster] save blocked:", error)
                    }
                }
            }

            dismiss()
        } catch {
            context.rollback()
            saveError = "Could not save movie: \(error.localizedDescription)"
            print("Save movie failed:", error)
        }

    }
}

// MARK: - Draft

struct MemberFeedbackDraft: Equatable {
    var rating: Double = 0.0
    var slept: Bool = false
    var notes: String = ""
}

// MARK: - Binding helpers

private extension Binding where Value == MemberFeedbackDraft {
    var rating: Binding<Double> {
        Binding<Double>(
            get: { wrappedValue.rating },
            set: { wrappedValue.rating = $0 }
        )
    }

    var slept: Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.slept },
            set: { wrappedValue.slept = $0 }
        )
    }

    var notes: Binding<String> {
        Binding<String>(
            get: { wrappedValue.notes },
            set: { wrappedValue.notes = $0 }
        )
    }
}
