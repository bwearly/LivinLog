import SwiftUI
import CoreData
import UIKit

struct RecipesListView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState
    let household: Household
    let member: HouseholdMember?

    @FetchRequest private var recipes: FetchedResults<Recipe>
    @FetchRequest private var categories: FetchedResults<RecipeCategory>

    @State private var showingAddRecipe = false
    @State private var searchText = ""
    @State private var selectedCategoryIDs: Set<NSManagedObjectID> = []

    private var canWrite: Bool {
        IdentityStore.canAct(as: member, currentUserRecordName: appState.currentUserRecordName)
    }

    init(household: Household, member: HouseholdMember?) {
        self.household = household
        self.member = member

        _recipes = FetchRequest<Recipe>(
            sortDescriptors: [NSSortDescriptor(keyPath: \Recipe.title, ascending: true)],
            predicate: householdScopedPredicate(household, idKey: "householdId"),
            animation: .default
        )

        // Fetched on the scalar `householdId`, which both local creates and inbound sync set
        // (the `household` relationship added in Phase 4a is also set). See RecipeStore.swift.
        if let householdID = household.id {
            _categories = FetchRequest<RecipeCategory>(
                sortDescriptors: [NSSortDescriptor(keyPath: \RecipeCategory.name, ascending: true)],
                predicate: NSPredicate(format: "householdId == %@", householdID as NSUUID),
                animation: .default
            )
        } else {
            _categories = FetchRequest<RecipeCategory>(
                sortDescriptors: [NSSortDescriptor(keyPath: \RecipeCategory.name, ascending: true)],
                predicate: NSPredicate(value: false)
            )
        }
    }

    private var filteredRecipes: [Recipe] {
        var list = Array(recipes)

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            list = list.filter { recipe in
                let title = (recipe.title ?? "").lowercased()
                if title.contains(query) { return true }

                let ingredientNames = recipe.sortedIngredients.map { ($0.name ?? "").lowercased() }
                if ingredientNames.contains(where: { $0.contains(query) }) { return true }

                let categoryNames = recipe.sortedCategories.map { ($0.name ?? "").lowercased() }
                return categoryNames.contains(where: { $0.contains(query) })
            }
        }

        if !selectedCategoryIDs.isEmpty {
            list = list.filter { recipe in
                let recipeCategoryIDs = Set(recipe.sortedCategories.map(\.objectID))
                return !recipeCategoryIDs.isDisjoint(with: selectedCategoryIDs)
            }
        }

        return list
    }

    var body: some View {
        List {
            if !categories.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(categories, id: \.objectID) { category in
                                let isSelected = selectedCategoryIDs.contains(category.objectID)
                                Button {
                                    toggleCategoryFilter(category.objectID)
                                } label: {
                                    SharedViews.AccentPill(
                                        category.name ?? "Untitled",
                                        systemImage: isSelected ? "checkmark" : nil,
                                        style: .recipes
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if filteredRecipes.isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategoryIDs.isEmpty {
                    SharedViews.SoftEmptyState(
                        title: "No recipes yet",
                        systemImage: "fork.knife",
                        style: .recipes,
                        description: "Add your first household recipe."
                    )
                    .listRowBackground(Color.clear)

                    Button("Add Recipe") {
                        showingAddRecipe = true
                    }
                    .foregroundStyle(AppCategoryStyle.recipes.accent)
                    .disabled(!canWrite)
                    .listRowBackground(Color.clear)
                } else {
                    SharedViews.SoftEmptyState(
                        title: "No results",
                        systemImage: "magnifyingglass",
                        style: .recipes,
                        description: "Try another title, ingredient, or category."
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(filteredRecipes, id: \.objectID) { recipe in
                    NavigationLink {
                        RecipeDetailView(recipe: recipe, household: household, member: member)
                    } label: {
                        RecipeRow(recipe: recipe)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Recipes")
        .searchable(text: $searchText, prompt: "Search title, ingredient, category…")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAddRecipe = true
                } label: {
                    Label("Add Recipe", systemImage: "plus")
                }
                .disabled(!canWrite)
            }
        }
        .sheet(isPresented: $showingAddRecipe) {
            NavigationStack {
                AddEditRecipeView(household: household)
            }
        }
    }

    private func toggleCategoryFilter(_ objectID: NSManagedObjectID) {
        if selectedCategoryIDs.contains(objectID) {
            selectedCategoryIDs.remove(objectID)
        } else {
            selectedCategoryIDs.insert(objectID)
        }
    }
}

private struct RecipeRow: View {
    let recipe: Recipe

    private var servingsText: String {
        "Serves \(recipe.servings)"
    }

    private var ingredientCountText: String {
        let count = recipe.sortedIngredients.count
        return count == 1 ? "1 ingredient" : "\(count) ingredients"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RecipeThumbnail(photoData: recipe.sortedPhotos.first?.photoData)

            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.title ?? "Untitled")
                    .font(.headline)
                    .lineLimit(1)

                if let author = recipe.authorSource, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    SharedViews.AccentPill(servingsText, systemImage: "person.2", style: .recipes)
                    SharedViews.AccentPill(ingredientCountText, systemImage: "list.bullet", style: .recipes)
                }

                if !recipe.sortedCategories.isEmpty {
                    Text(recipe.sortedCategories.compactMap(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .subtleCategoryRowCard(style: .recipes, horizontalPadding: 9, verticalPadding: 6)
    }
}

private struct RecipeThumbnail: View {
    let photoData: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(AppCategoryStyle.recipes.gradient.opacity(0.45))

            if let photoData,
               let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "fork.knife")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 50, height: 50)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppCategoryStyle.recipes.accent.opacity(0.22), lineWidth: 0.75)
        )
        .clipped()
    }
}
