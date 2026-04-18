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

    // Genres
    @State private var selectedGenres: Set<String> = []
    @State private var showGenrePicker = false

    // Feedback drafts
    @State private var feedbackByMemberID: [NSManagedObjectID: MemberFeedbackDraft] = [:]

    private let persistentContainer = PersistenceController.shared.container

    private let mpaaOptions: [String] = ["—", "G", "PG", "PG-13", "R", "NC-17", "Not Rated"]
    private let allGenres: [String] = [
        "Action","Adventure","Animation","Comedy","Crime","Documentary","Drama","Family",
        "Fantasy","History","Horror","Music","Mystery","Romance","Sci-Fi","Thriller","War","Western"
    ]

    var body: some View {
        Form {
            Section("Movie") {
                TextField("Title", text: $title)

                TextField("Year", text: $yearText)
                    .keyboardType(.numberPad)

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
            }

            Section("Feedback") {
                if let actingMember {
                    ForEach([actingMember]) { m in
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
            }
        }
        .navigationTitle("Add Movie")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveMovie() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || actingMember == nil)
            }
        }
        .navigationDestination(isPresented: $showGenrePicker) {
            GenrePickerView(title: "Select Genres", allGenres: allGenres, selected: $selectedGenres)
        }
        .onAppear {
            seedFeedbackDraftsIfNeeded()
        }
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
        for m in [actingMember].compactMap({ $0 }) {
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
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actingMember != nil else { return }
        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else { return }

        let movie = Movie(context: context)
        if let store = scopedHousehold.objectID.persistentStore {
            context.assign(movie, to: store)
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

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        movie.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        // Feedback rows
        var createdFeedbacks: [MovieFeedback] = []
        for m in [actingMember].compactMap({ $0 }) {
            let draft = feedbackByMemberID[m.objectID] ?? MemberFeedbackDraft()
            if isDraftEmpty(draft) { continue }

            guard let memberInContext = (try? context.existingObject(with: m.objectID)) as? HouseholdMember else {
                continue
            }

            let fb = MovieFeedback(context: context)
            if let store = scopedHousehold.objectID.persistentStore {
                context.assign(fb, to: store)
            }
            fb.id = UUID()
            fb.updatedAt = Date()
            fb.rating = draft.rating
            fb.slept = draft.slept

            let n = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            fb.notes = n.isEmpty ? nil : n

            fb.household = scopedHousehold
            fb.movie = movie
            fb.member = memberInContext
            createdFeedbacks.append(fb)
        }
        
        // ✅ Add initial watch history record on create
        let v = Viewing(context: context)
        if let store = scopedHousehold.objectID.persistentStore {
            context.assign(v, to: store)
        }
        // awakeFromInsert already sets id + watchedOn
        v.isRewatch = false
        v.watchedOn = watchedOn
        v.notes = nil
        v.movie = movie
        v.household = scopedHousehold

        do {
            try context.save()
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
            Task {
                let url = await OMDbPosterService.posterURL(title: movie.title, year: movie.year)
                let httpsURL = url.flatMap {
                    URL(string: $0.absoluteString.replacingOccurrences(of: "http://", with: "https://"))
                }

                await MainActor.run {
                    movie.posterURL = httpsURL?.absoluteString
                    try? context.save()
                }
            }

            dismiss()
        } catch {
            context.rollback()
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
