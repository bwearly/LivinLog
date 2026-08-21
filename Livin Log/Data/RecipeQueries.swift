//
//  RecipeQueries.swift
//  Livin Log
//
//  Created by Blake Early on 8/21/26.
//
//  Read-side helpers for the Recipe model. `RecipeStore.swift` owns writes; this file centralizes
//  the "unordered NSSet relationship -> ordered array by manual position" conversion so list,
//  detail, and add/edit views don't each re-implement the same sort.

import Foundation

extension Recipe {
    var sortedIngredients: [RecipeIngredient] {
        let set = ingredients as? Set<RecipeIngredient> ?? []
        return set.sorted { $0.position < $1.position }
    }

    var sortedSteps: [RecipeStep] {
        let set = steps as? Set<RecipeStep> ?? []
        return set.sorted { $0.position < $1.position }
    }

    var sortedPhotos: [RecipePhoto] {
        let set = photos as? Set<RecipePhoto> ?? []
        return set.sorted { $0.position < $1.position }
    }

    var sortedCategories: [RecipeCategory] {
        let set = categories as? Set<RecipeCategory> ?? []
        return set.sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
    }
}

/// A run of consecutive `RecipeStep`s sharing the same `sectionTitle` (nil included) — the
/// display grouping for sectioned instructions, per the flat `sectionTitle` schema decision.
struct RecipeStepGroup: Identifiable {
    let id = UUID()
    let title: String?
    let steps: [RecipeStep]
}

func groupedRecipeSteps(_ steps: [RecipeStep]) -> [RecipeStepGroup] {
    var groups: [RecipeStepGroup] = []
    for step in steps {
        if let last = groups.last, last.title == step.sectionTitle {
            let merged = RecipeStepGroup(title: last.title, steps: last.steps + [step])
            groups[groups.count - 1] = merged
        } else {
            groups.append(RecipeStepGroup(title: step.sectionTitle, steps: [step]))
        }
    }
    return groups
}

/// Rounds a scaled ingredient amount to 2 decimal places and trims trailing zeros
/// (e.g. 3.0 -> "3", 1.667 -> "1.67") — plain decimal rounding rather than snapping to
/// cooking fractions (1/8 etc.), chosen for exactness and simplicity; easy to swap for a
/// fraction formatter later if desired.
func formattedRecipeAmount(_ amount: Double) -> String {
    let rounded = (amount * 100).rounded() / 100
    if rounded == rounded.rounded() {
        return String(Int(rounded))
    }
    var text = String(format: "%.2f", rounded)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}

func scaledIngredientAmount(_ ingredient: RecipeIngredient, baseServings: Int16, currentServings: Int) -> Double {
    let base = max(Double(baseServings), 1)
    let factor = Double(currentServings) / base
    return ingredient.amount * factor
}
