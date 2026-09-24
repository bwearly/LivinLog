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
    /// Ingredient and step rows are deleted and recreated from the passed-in arrays on every
    /// save rather than diffed against existing rows. That's simpler and correctness-safe for
    /// the list sizes involved, at the cost of each edit generating fresh CKRecord IDs for them.
    /// Photos are the exception (Phase 4a): an existing `RecipePhoto` whose bytes are unchanged
    /// is reused (only its `position` may change), so editing a recipe never re-uploads its
    /// photo assets; only added photos are created and removed ones deleted. `position` is
    /// reassigned sequentially from each
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

        if let existingIngredients = recipe.ingredients as? Set<RecipeIngredient> {
            existingIngredients.forEach(context.delete)
        }
        var ingredientPosition: Int32 = 0
        for input in ingredients {
            let trimmedName = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }

            let ingredient = RecipeIngredient(context: context)
            assignIfInserted(ingredient, to: store, in: context)
            ingredient.id = UUID()
            ingredient.amount = input.amount
            let trimmedUnit = (input.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            ingredient.unit = trimmedUnit.isEmpty ? nil : trimmedUnit
            ingredient.name = trimmedName
            ingredient.position = ingredientPosition
            ingredient.recipe = recipe
            ingredientPosition += 1
        }

        if let existingSteps = recipe.steps as? Set<RecipeStep> {
            existingSteps.forEach(context.delete)
        }
        var stepPosition: Int32 = 0
        for input in steps {
            let trimmedText = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { continue }

            let step = RecipeStep(context: context)
            assignIfInserted(step, to: store, in: context)
            step.id = UUID()
            step.text = trimmedText
            let trimmedSection = (input.sectionTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            step.sectionTitle = trimmedSection.isEmpty ? nil : trimmedSection
            step.position = stepPosition
            step.recipe = recipe
            stepPosition += 1
        }

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
