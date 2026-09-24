//
//  RecipeStore.swift
//  Livin Log
//
//  Created by Blake Early on 8/21/26.
//

import CoreData

/// One ingredient row as edited in the UI, before it's written to a `RecipeIngredient`.
/// Amounts stay numeric (rather than free text) so the servings adjuster can scale them.
struct RecipeIngredientInput {
    var amount: Double
    var unit: String?
    var name: String
}

/// One instruction row as edited in the UI, before it's written to a `RecipeStep`.
/// `sectionTitle` is optional — consecutive steps sharing a non-nil title render grouped
/// under that header; steps with a nil `sectionTitle` render plain/ungrouped.
struct RecipeStepInput {
    var text: String
    var sectionTitle: String?
}

enum RecipeStore {
    /// Creates or updates a `Recipe` and fully replaces its `RecipeIngredient`/`RecipeStep`/
    /// `RecipePhoto` children and `RecipeCategory` assignment in one save, following the
    /// household-scoped save triad established in `HouseholdScope.swift` and used by
    /// `AddEditPuzzleView.savePuzzle()` (`activeHouseholdInContext` → `assignIfInserted` →
    /// `storeForParent`).
    ///
    /// Children are updated in place, never deleted-and-recreated (Phase 4a), so an edit sends
    /// only the records that actually changed and two devices editing the same recipe update
    /// the same records instead of each minting new ones (which would duplicate rows):
    /// - Ingredients and steps are matched by position: the i-th non-blank form row updates the
    ///   i-th existing row in `sortedIngredients`/`sortedSteps` order (position, then
    ///   recordName -- the same order the editor was seeded from). Fields are assigned only
    ///   when they differ; rows are created only for added positions and deleted only for
    ///   removed ones.
    /// - Photos are matched by bytes: an unchanged photo keeps its row (only `position` may
    ///   change), so editing a recipe never re-uploads its photo assets.
    /// `position` is reassigned sequentially from each
    /// array's order, since this model — like the rest of the app — uses a manual position
    /// attribute instead of Core Data ordered relationships (unsupported under
    /// `NSPersistentCloudKitContainer`).
    ///
    /// Blank ingredient/step rows (empty name/text after trimming) are silently dropped so a
    /// half-filled add row left in the form doesn't produce an empty persisted row.
    ///
    /// Throws and leaves the context uncommitted on failure — callers should `context.rollback()`
    /// on error, matching `AddEditPuzzleView.savePuzzle()`.
    @discardableResult
    static func save(
        editingRecipe: Recipe?,
        household: Household,
        title: String,
        servings: Int16,
        authorSource: String?,
        notes: String?,
        ingredients: [RecipeIngredientInput],
        steps: [RecipeStepInput],
        categories: [RecipeCategory],
        photoData: [Data],
        context: NSManagedObjectContext
    ) throws -> Recipe {
        let now = Date()
        guard let scopedHousehold = activeHouseholdInContext(household, context: context) else {
            throw StoreValidationError.missingReferenceStore("household")
        }

        let recipe: Recipe
        if let editingRecipe,
           let existing = (try? context.existingObject(with: editingRecipe.objectID)) as? Recipe {
            recipe = existing
        } else {
            recipe = Recipe(context: context)
        }

        let store = editingRecipe != nil ? storeForParent(recipe) : scopedHousehold.objectID.persistentStore
        assignIfInserted(recipe, to: store, in: context)

        if recipe.id == nil { recipe.id = UUID() }
        if recipe.createdAt == nil { recipe.createdAt = now }
        recipe.updatedAt = now
        recipe.household = scopedHousehold
        recipe.householdId = scopedHousehold.id

        recipe.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.servings = servings

        let trimmedAuthor = (authorSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.authorSource = trimmedAuthor.isEmpty ? nil : trimmedAuthor

        let trimmedNotes = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        // Categories may have been fetched under a different context/store than the recipe
        // (e.g. a household mid-share transition) — guard against wiring a cross-store
        // relationship the same way MovieFeedbackStore/MovieStoreSafety do for Movie graphs.
        if !categories.isEmpty {
            let labeledCategories: [(String, NSManagedObject?)] = categories.enumerated().map { index, category in
                ("category[\(index)]", category)
            }
            try context.validateSamePersistentStore([("recipe", recipe)] + labeledCategories)
        }
        // Only reassign when the set actually changed, so an unchanged edit doesn't touch it.
        let newCategories = Set(categories)
        if ((recipe.categories as? Set<RecipeCategory>) ?? []) != newCategories {
            recipe.categories = NSSet(set: newCategories)
        }
        // Keep the synced category list (linked + any still in flight from another device)
        // current, so a category removed here isn't re-added by inbound link retry.
        let categoryNamesRaw = SyncRecordMapping.encodeCategoryRecordNames(
            SyncRecordMapping.effectiveCategoryRecordNames(for: recipe, context: context)
        )
        if recipe.categoryRecordNamesRaw != categoryNamesRaw {
            recipe.categoryRecordNamesRaw = categoryNamesRaw
        }

        // Ingredients: update in place by position (see the doc comment above).
        let existingIngredients = recipe.sortedIngredients
        let ingredientRows = ingredients.compactMap { input -> (name: String, unit: String?, amount: Double)? in
            let trimmedName = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }
            let trimmedUnit = (input.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmedName, trimmedUnit.isEmpty ? nil : trimmedUnit, input.amount)
        }
        for (index, row) in ingredientRows.enumerated() {
            let position = Int32(index)
            let ingredient: RecipeIngredient
            if index < existingIngredients.count {
                ingredient = existingIngredients[index]
            } else {
                ingredient = RecipeIngredient(context: context)
                assignIfInserted(ingredient, to: store, in: context)
                ingredient.id = UUID()
                ingredient.recipe = recipe
            }
            if ingredient.name != row.name { ingredient.name = row.name }
            if ingredient.unit != row.unit { ingredient.unit = row.unit }
            if ingredient.amount != row.amount { ingredient.amount = row.amount }
            if ingredient.position != position { ingredient.position = position }
        }
        existingIngredients.dropFirst(ingredientRows.count).forEach(context.delete)

        // Steps: same in-place update by position.
        let existingSteps = recipe.sortedSteps
        let stepRows = steps.compactMap { input -> (text: String, sectionTitle: String?)? in
            let trimmedText = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return nil }
            let trimmedSection = (input.sectionTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmedText, trimmedSection.isEmpty ? nil : trimmedSection)
        }
        for (index, row) in stepRows.enumerated() {
            let position = Int32(index)
            let step: RecipeStep
            if index < existingSteps.count {
                step = existingSteps[index]
            } else {
                step = RecipeStep(context: context)
                assignIfInserted(step, to: store, in: context)
                step.id = UUID()
                step.recipe = recipe
            }
            if step.text != row.text { step.text = row.text }
            if step.sectionTitle != row.sectionTitle { step.sectionTitle = row.sectionTitle }
            if step.position != position { step.position = position }
        }
        existingSteps.dropFirst(stepRows.count).forEach(context.delete)

        // Reuse unchanged photos (matched by bytes), create rows only for new ones, delete
        // rows for removed ones -- see the doc comment above.
        var unmatchedPhotos = Array((recipe.photos as? Set<RecipePhoto>) ?? [])
        for (index, data) in photoData.enumerated() {
            let position = Int32(index)
            if let matchIndex = unmatchedPhotos.firstIndex(where: { $0.photoData == data }) {
                let existing = unmatchedPhotos.remove(at: matchIndex)
                if existing.position != position { existing.position = position }
                continue
            }
            let photo = RecipePhoto(context: context)
            assignIfInserted(photo, to: store, in: context)
            photo.id = UUID()
            photo.photoData = data
            photo.position = position
            photo.recipe = recipe
        }
        unmatchedPhotos.forEach(context.delete)

        try context.save()

        #if DEBUG
        debugPrintHouseholdDiagnostics(household: scopedHousehold, context: context, reason: "recipe-save")
        debugLogHouseholdAssignment(entityName: "Recipe", object: recipe, household: scopedHousehold, context: context)
        #endif

        return recipe
    }

    static func delete(_ recipe: Recipe, context: NSManagedObjectContext) throws {
        context.delete(recipe)
        try context.save()
    }

    /// Household-scoped get-or-create for a category name, so any member can introduce a new
    /// category inline while editing a recipe (no separate management screen). Matching is
    /// case-insensitive so "breakfast" and "Breakfast" don't produce duplicate categories.
    ///
    /// Fetches directly on the scalar `householdId`. (Phase 4a added a `household`
    /// relationship for sync zone + cascade, set below on create and by inbound sync, but
    /// `householdId` is set in both places too, so this lookup is unchanged.)
    static func fetchOrCreateCategory(
        named rawName: String,
        household: Household,
        context: NSManagedObjectContext
    ) throws -> RecipeCategory? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let scopedHousehold = activeHouseholdInContext(household, context: context),
              let householdID = scopedHousehold.id else {
            throw StoreValidationError.missingReferenceStore("household")
        }

        let request = NSFetchRequest<RecipeCategory>(entityName: "RecipeCategory")
        request.predicate = NSPredicate(format: "householdId == %@ AND name ==[c] %@", householdID as NSUUID, trimmed)
        request.fetchLimit = 1
        if let existing = try context.fetch(request).first {
            return existing
        }

        let category = RecipeCategory(context: context)
        assignIfInserted(category, to: scopedHousehold.objectID.persistentStore, in: context)
        category.id = UUID()
        category.name = trimmed
        category.householdId = householdID
        // Phase 4a: the household link gives the category its CloudKit zone and makes it
        // cascade-delete with the household.
        category.household = scopedHousehold
        return category
    }

    /// All categories for a household, sorted by name — for the multi-select UI's option list.
    static func fetchCategories(household: Household, context: NSManagedObjectContext) throws -> [RecipeCategory] {
        guard let scopedHousehold = activeHouseholdInContext(household, context: context),
              let householdID = scopedHousehold.id else {
            return []
        }

        let request = NSFetchRequest<RecipeCategory>(entityName: "RecipeCategory")
        request.predicate = NSPredicate(format: "householdId == %@", householdID as NSUUID)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \RecipeCategory.name, ascending: true)]
        return try context.fetch(request)
    }
}
