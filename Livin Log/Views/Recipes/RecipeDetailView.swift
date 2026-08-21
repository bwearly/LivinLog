import SwiftUI
import CoreData
import UIKit

struct RecipeDetailView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState
    let recipe: Recipe
    let household: Household
    let member: HouseholdMember?

    @State private var showingEdit = false
    @State private var currentServings: Int = 1
    @State private var didSeedServings = false

    private var canWrite: Bool {
        IdentityStore.canAct(as: member, appUser: appState.appUser, context: context)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !recipe.sortedPhotos.isEmpty {
                    RecipePhotoCarousel(photos: recipe.sortedPhotos)
                }

                header

                servingsCard

                ingredientsCard

                instructionsCard

                if let notes = recipe.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    card(title: "Notes") {
                        Text(notes)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") {
                    showingEdit = true
                }
                .disabled(!canWrite)
            }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                AddEditRecipeView(household: household, editingRecipe: recipe)
            }
        }
        .onAppear {
            if !didSeedServings {
                didSeedServings = true
                currentServings = max(Int(recipe.servings), 1)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recipe.title ?? "Untitled")
                .font(.title2)
                .fontWeight(.semibold)

            if let author = recipe.authorSource, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !recipe.sortedCategories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(recipe.sortedCategories, id: \.objectID) { category in
                            SharedViews.AccentPill(category.name ?? "Untitled", style: .recipes)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var servingsCard: some View {
        card(title: "Servings") {
            HStack {
                Text("\(currentServings) \(currentServings == 1 ? "serving" : "servings")")
                    .font(.subheadline)
                Spacer()
                Stepper("", value: $currentServings, in: 1...50)
                    .labelsHidden()
            }
            if Int(recipe.servings) != currentServings {
                Text("Amounts below are scaled from the original \(recipe.servings) servings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ingredientsCard: some View {
        card(title: "Ingredients") {
            if recipe.sortedIngredients.isEmpty {
                Text("No ingredients added.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recipe.sortedIngredients, id: \.objectID) { ingredient in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(ingredientLine(ingredient))
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var instructionsCard: some View {
        card(title: "Instructions") {
            if recipe.sortedSteps.isEmpty {
                Text("No instructions added.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groupedRecipeSteps(recipe.sortedSteps)) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            if let title = group.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppCategoryStyle.recipes.accent)
                            }
                            ForEach(Array(group.steps.enumerated()), id: \.element.objectID) { index, step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(index + 1).")
                                        .foregroundStyle(.secondary)
                                        .font(.subheadline.monospacedDigit())
                                    Text(step.text ?? "")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func ingredientLine(_ ingredient: RecipeIngredient) -> String {
        let scaled = scaledIngredientAmount(ingredient, baseServings: recipe.servings, currentServings: currentServings)
        let amountText = formattedRecipeAmount(scaled)
        var parts = [amountText]
        if let unit = ingredient.unit, !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(unit)
        }
        parts.append(ingredient.name ?? "")
        return parts.joined(separator: " ")
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
        )
    }
}

private struct RecipePhotoCarousel: View {
    let photos: [RecipePhoto]

    var body: some View {
        TabView {
            ForEach(photos, id: \.objectID) { photo in
                if let data = photo.photoData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .clipped()
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
        .frame(height: 260)
    }
}
