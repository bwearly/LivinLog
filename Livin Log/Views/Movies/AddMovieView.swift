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

            Section("Feedback (per member)") {
                let members = fetchedMembers()
                if members.isEmpty {
                    Text("No household members found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(members) { m in
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
                }
            }
        }
        .navigationTitle("Add Movie")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveMovie() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationDestination(isPresented: $showGenrePicker) {
            GenrePickerView(title: "Select Genres", allGenres: allGenres, selected: $selectedGenres)
        }
        .onAppear {
            ensureDefaultMemberExists()
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
        let req = NSFetchRequest<HouseholdMember>(entityName: "HouseholdMember")
        if let hid = household.id {
            req.predicate = NSPredicate(format: "household.id == %@", hid as CVarArg)
        } else {
            req.predicate = NSPredicate(format: "household == %@", household)
        }
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return (try? context.fetch(req)) ?? []
    }

    private func ensureDefaultMemberExists() {
        if !fetchedMembers().isEmpty { return }

        let me = HouseholdMember(context: context)
        me.id = UUID()
        me.createdAt = Date()
        me.displayName = member?.displayName ?? "Me"
        me.household = household

        do { try context.save() } catch { context.rollback() }
    }

    private func seedFeedbackDraftsIfNeeded() {
        for m in fetchedMembers() {
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

        let movie = Movie(context: context)
        movie.id = UUID()
        movie.createdAt = Date()
        movie.title = trimmedTitle

        movie.household = household
        
        // Ensure household has stable id
        if household.id == nil {
            household.id = UUID()
        }

        // ✅ Store householdID directly on Movie
        movie.householdID = household.id

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
        for m in fetchedMembers() {
            let draft = feedbackByMemberID[m.objectID] ?? MemberFeedbackDraft()
            if isDraftEmpty(draft) { continue }

            let fb = MovieFeedback(context: context)
            fb.id = UUID()
            fb.updatedAt = Date()
            fb.rating = draft.rating
            fb.slept = draft.slept

            let n = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            fb.notes = n.isEmpty ? nil : n

            fb.household = household
            fb.movie = movie
            fb.member = m
        }
        
        // ✅ Add initial watch history record on create
        let v = Viewing(context: context)
        // awakeFromInsert already sets id + watchedOn
        v.isRewatch = false
        v.watchedOn = watchedOn
        v.notes = nil
        v.movie = movie
        v.household = household

        do {
            try context.save()

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
