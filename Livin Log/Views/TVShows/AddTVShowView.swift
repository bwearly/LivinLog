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
                .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canWrite)
            }
        }
        .alert("Could Not Save TV Show", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "The TV show could not be saved.")
        }
    }

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

        // Store rating as text (Core Data: TVShow.ratingText : String)
        tvShow.ratingText = contentRating.rawValue

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        tvShow.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        // ✅ Fetch poster and store it on TVShow.posterURL (Core Data: String)
        let fetched = await OMDbPosterService.posterURL(title: tvShow.title, year: tvShow.year)
        tvShow.posterURL = fetched?.absoluteString

        do {
            let objectsToValidate: [(String, NSManagedObject?)] = [("tvShow", tvShow), ("household", scopedHousehold)]
            context.debugLogStoreSafeSave(entityName: "TVShow", household: scopedHousehold, member: member, objects: objectsToValidate)
            try context.validateSamePersistentStore(objectsToValidate)
            try TVShowStoreSafety.validateGraph(tvShow: tvShow, context: context, operation: "TVShow.add", assignedBeforeRelationships: true)
            try context.save()
            print("ℹ️ TVShow inherits household share via parent household relationship (no per-object share mutation)")
#if DEBUG
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
