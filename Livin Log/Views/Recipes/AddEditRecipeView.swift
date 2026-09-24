import SwiftUI
import CoreData
import PhotosUI
import UIKit

struct AddEditRecipeView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let household: Household
    let editingRecipe: Recipe?

    @State private var title = ""
    @State private var authorSource = ""
    @State private var servings = 4
    @State private var notes = ""

    @State private var ingredientDrafts: [IngredientDraft] = [IngredientDraft()]
    @State private var stepDrafts: [StepDraft] = [StepDraft()]

    @State private var allCategories: [RecipeCategory] = []
    @State private var selectedCategoryIDs: Set<NSManagedObjectID> = []
    @State private var pendingNewCategoryNames: [String] = []
    @State private var newCategoryText = ""

    // A recipe can carry more than one photo, unlike LLPuzzle's single `photoData` — capped to
    // bound CloudKit asset sync cost per the Part 1 investigation (each photo is its own
    // external-storage CKAsset).
    private static let maxPhotos = 6
    @State private var photosData: [Data] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingPhotoSourceDialog = false
    @State private var showingPhotoLibraryPicker = false
    @State private var showingCamera = false

    // "Scan a Recipe Photo" — on-device Vision OCR, distinct from the photo-attachment flow
    // above: this never touches `photosData`, it only pre-fills the text fields below.
    @State private var showingScanSourceDialog = false
    @State private var showingScanPhotoLibraryPicker = false
    @State private var showingScanCamera = false
    @State private var scanPhotoItem: PhotosPickerItem?
    @State private var isScanning = false
    @State private var scanHintMessage: String?

    @State private var showingDeleteAlert = false
    @State private var isSaving = false
    @State private var didSeed = false

    private var canWrite: Bool {
        appState.isCurrentMemberAuthorized()
    }

    init(household: Household, editingRecipe: Recipe? = nil) {
        self.household = household
        self.editingRecipe = editingRecipe
    }

    private var isEditing: Bool { editingRecipe != nil }

    var body: some View {
        Form {
            scanSection
            photosSection
            recipeSection
            categoriesSection
            ingredientsSection
            instructionsSection

            if isEditing {
                Section {
                    Button("Delete Recipe", role: .destructive) {
                        showingDeleteAlert = true
                    }
                    .disabled(!canWrite)
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Recipe" : "Add Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") {
                    saveRecipe()
                }
                .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canWrite)
            }
        }
        .confirmationDialog("Choose Photo Source", isPresented: $showingPhotoSourceDialog) {
            Button {
                showingPhotoLibraryPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }

            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showingCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
        }
        .photosPicker(
            isPresented: $showingPhotoLibraryPicker,
            selection: $selectedPhotoItem,
            matching: .images
        )
        .sheet(isPresented: $showingCamera) {
            CameraPicker { image in
                // Phase 4a: stored at the synced size (1600px / JPEG 0.7), see SyncImageAsset.
                guard let image, let jpeg = image.jpegData(compressionQuality: 1.0).flatMap(SyncImageAsset.downscaledJPEG) else { return }
                appendPhoto(jpeg)
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let jpeg = SyncImageAsset.downscaledJPEG(data) {
                    await MainActor.run {
                        appendPhoto(jpeg)
                        selectedPhotoItem = nil
                    }
                }
            }
        }
        .confirmationDialog("Scan Recipe Photo", isPresented: $showingScanSourceDialog) {
            Button {
                showingScanPhotoLibraryPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }

            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showingScanCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
        }
        .photosPicker(
            isPresented: $showingScanPhotoLibraryPicker,
            selection: $scanPhotoItem,
            matching: .images
        )
        .sheet(isPresented: $showingScanCamera) {
            CameraPicker { image in
                guard let image else { return }
                runScan(on: image)
            }
        }
        .onChange(of: scanPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                // Load the original picked image for OCR — deliberately not recompressed the
                // way appendPhoto's downscaled (SyncImageAsset) path is, since Vision
                // does better against the source image than a requantized storage copy.
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        scanPhotoItem = nil
                    }
                    runScan(on: image)
                }
            }
        }
        .alert("Delete this recipe?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) { deleteRecipe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
        .onAppear {
            if !didSeed {
                didSeed = true
                seedIfEditing()
                loadCategories()
            }
        }
    }

    // MARK: - Scan

    private var scanSection: some View {
        Section {
            Button {
                showingScanSourceDialog = true
            } label: {
                if isScanning {
                    Label("Scanning…", systemImage: "text.viewfinder")
                } else {
                    Label("Scan a Recipe Photo", systemImage: "text.viewfinder")
                }
            }
            .disabled(!canWrite || isScanning)

            if let scanHintMessage {
                Text(scanHintMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Runs on-device Vision OCR against `image`, then writes the best-effort split straight
    /// into the same editable `@State` fields the rest of this form uses — no separate
    /// confirmation screen. Nothing here touches Core Data; the user still has to review the
    /// pre-filled rows and tap Save (or Cancel) like any other edit, same as typing them by hand.
    private func runScan(on image: UIImage) {
        guard !isScanning else { return }
        isScanning = true
        scanHintMessage = nil

        Task {
            do {
                let lines = try await RecipeOCR.recognizeText(in: image)
                let result = RecipeOCR.classify(lines: lines)
                await MainActor.run {
                    applyScanResult(result)
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    scanHintMessage = "Couldn't read text from that photo. Try a clearer, well-lit photo of the recipe."
                    isScanning = false
                }
                print("Recipe OCR failed:", error)
            }
        }
    }

    private func applyScanResult(_ result: RecipeOCRResult) {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let titleGuess = result.titleGuess {
            title = titleGuess
        }

        let scannedIngredients = result.ingredientLines.map { line -> IngredientDraft in
            let parsed = RecipeOCR.parseIngredientLine(line)
            return IngredientDraft(amountText: parsed.amountText, unit: parsed.unit, name: parsed.name)
        }
        if !scannedIngredients.isEmpty {
            if ingredientDrafts.count == 1, ingredientDrafts[0].isBlank {
                ingredientDrafts = scannedIngredients
            } else {
                ingredientDrafts.append(contentsOf: scannedIngredients)
            }
        }

        let scannedSteps = result.instructionLines.map { StepDraft(text: $0, sectionTitle: "") }
        if !scannedSteps.isEmpty {
            if stepDrafts.count == 1, stepDrafts[0].isBlank {
                stepDrafts = scannedSteps
            } else {
                stepDrafts.append(contentsOf: scannedSteps)
            }
        }

        if scannedIngredients.isEmpty && scannedSteps.isEmpty {
            scanHintMessage = "Didn't find any recognizable text in that photo."
        } else {
            scanHintMessage = "Best-effort scan — review and edit the ingredients and instructions below before saving."
        }
    }

    // MARK: - Photos

    private var photosSection: some View {
        Section("Photos (\(photosData.count)/\(Self.maxPhotos))") {
            if !photosData.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(photosData.enumerated()), id: \.offset) { index, data in
                            photoThumbnail(data: data, index: index)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Button {
                selectedPhotoItem = nil
                showingPhotoSourceDialog = true
            } label: {
                Label("Add Photo", systemImage: "photo")
            }
            .disabled(!canWrite || photosData.count >= Self.maxPhotos)

            if photosData.count >= Self.maxPhotos {
                Text("Up to \(Self.maxPhotos) photos per recipe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func photoThumbnail(data: Data, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 90, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button {
                removePhoto(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .padding(4)
            .disabled(!canWrite)
        }
    }

    private func appendPhoto(_ data: Data) {
        guard photosData.count < Self.maxPhotos else { return }
        photosData.append(data)
    }

    private func removePhoto(at index: Int) {
        guard photosData.indices.contains(index) else { return }
        photosData.remove(at: index)
    }

    // MARK: - Recipe fields

    private var recipeSection: some View {
        Section("Recipe") {
            TextField("Title", text: $title)
            TextField("Author / Source (optional)", text: $authorSource)
            Stepper("Servings: \(servings)", value: $servings, in: 1...50)

            TextEditor(text: $notes)
                .frame(minHeight: 90)
                .overlay(alignment: .topLeading) {
                    if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Notes (optional)")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                    }
                }
        }
    }

    // MARK: - Categories

    private var categoriesSection: some View {
        Section("Categories") {
            if !allCategories.isEmpty || !pendingNewCategoryNames.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(allCategories, id: \.objectID) { category in
                        CategoryChip(
                            name: category.name ?? "Untitled",
                            isSelected: selectedCategoryIDs.contains(category.objectID)
                        ) {
                            toggleExistingCategory(category.objectID)
                        }
                    }

                    ForEach(Array(pendingNewCategoryNames.enumerated()), id: \.offset) { index, name in
                        CategoryChip(name: name, isSelected: true) {
                            pendingNewCategoryNames.remove(at: index)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                TextField("New category", text: $newCategoryText)
                Button("Add") {
                    addPendingCategory()
                }
                .disabled(newCategoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(!canWrite)
        }
    }

    private func toggleExistingCategory(_ objectID: NSManagedObjectID) {
        if selectedCategoryIDs.contains(objectID) {
            selectedCategoryIDs.remove(objectID)
        } else {
            selectedCategoryIDs.insert(objectID)
        }
    }

    private func addPendingCategory() {
        let trimmed = newCategoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        newCategoryText = ""

        if let existing = allCategories.first(where: { ($0.name ?? "").caseInsensitiveCompare(trimmed) == .orderedSame }) {
            selectedCategoryIDs.insert(existing.objectID)
            return
        }
        if pendingNewCategoryNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return
        }
        pendingNewCategoryNames.append(trimmed)
    }

    private func loadCategories() {
        allCategories = (try? RecipeStore.fetchCategories(household: household, context: context)) ?? []
    }

    // MARK: - Ingredients

    private var ingredientsSection: some View {
        Section("Ingredients") {
            ForEach(ingredientDrafts.indices, id: \.self) { index in
                ingredientRow(index: index)
            }

            Button {
                ingredientDrafts.append(IngredientDraft())
            } label: {
                Label("Add Ingredient", systemImage: "plus")
            }
            .disabled(!canWrite)
        }
    }

    private func ingredientRow(index: Int) -> some View {
        HStack(spacing: 8) {
            TextField("Amt", text: $ingredientDrafts[index].amountText)
                .keyboardType(.decimalPad)
                .frame(width: 50)
            TextField("Unit", text: $ingredientDrafts[index].unit)
                .frame(width: 60)
            TextField("Ingredient", text: $ingredientDrafts[index].name)

            reorderMenu(
                canMoveUp: index > 0,
                canMoveDown: index < ingredientDrafts.count - 1,
                moveUp: { ingredientDrafts.swapAt(index, index - 1) },
                moveDown: { ingredientDrafts.swapAt(index, index + 1) },
                remove: { removeIngredient(at: index) }
            )
        }
        .disabled(!canWrite)
    }

    private func removeIngredient(at index: Int) {
        guard ingredientDrafts.indices.contains(index) else { return }
        ingredientDrafts.remove(at: index)
        if ingredientDrafts.isEmpty {
            ingredientDrafts.append(IngredientDraft())
        }
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        Section("Instructions") {
            ForEach(stepDrafts.indices, id: \.self) { index in
                stepRow(index: index)
            }

            Button {
                stepDrafts.append(StepDraft())
            } label: {
                Label("Add Step", systemImage: "plus")
            }
            .disabled(!canWrite)
        }
    }

    private func stepRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Section header (optional)", text: $stepDrafts[index].sectionTitle)
                    .font(.subheadline)
                Spacer()
                reorderMenu(
                    canMoveUp: index > 0,
                    canMoveDown: index < stepDrafts.count - 1,
                    moveUp: { stepDrafts.swapAt(index, index - 1) },
                    moveDown: { stepDrafts.swapAt(index, index + 1) },
                    remove: { removeStep(at: index) }
                )
            }

            TextEditor(text: $stepDrafts[index].text)
                .frame(minHeight: 60)
        }
        .disabled(!canWrite)
    }

    private func removeStep(at index: Int) {
        guard stepDrafts.indices.contains(index) else { return }
        stepDrafts.remove(at: index)
        if stepDrafts.isEmpty {
            stepDrafts.append(StepDraft())
        }
    }

    // MARK: - Shared row controls

    @ViewBuilder
    private func reorderMenu(
        canMoveUp: Bool,
        canMoveDown: Bool,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void,
        remove: @escaping () -> Void
    ) -> some View {
        Menu {
            Button {
                moveUp()
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(!canMoveUp)

            Button {
                moveDown()
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(!canMoveDown)

            Button(role: .destructive) {
                remove()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Seed / Save / Delete

    private func seedIfEditing() {
        guard let recipe = editingRecipe else { return }

        title = recipe.title ?? ""
        authorSource = recipe.authorSource ?? ""
        servings = max(Int(recipe.servings), 1)
        notes = recipe.notes ?? ""

        let ingredients = recipe.sortedIngredients
        ingredientDrafts = ingredients.isEmpty
            ? [IngredientDraft()]
            : ingredients.map {
                IngredientDraft(
                    amountText: formattedRecipeAmount($0.amount),
                    unit: $0.unit ?? "",
                    name: $0.name ?? ""
                )
            }

        let steps = recipe.sortedSteps
        stepDrafts = steps.isEmpty
            ? [StepDraft()]
            : steps.map { StepDraft(text: $0.text ?? "", sectionTitle: $0.sectionTitle ?? "") }

        selectedCategoryIDs = Set(recipe.sortedCategories.map(\.objectID))
        photosData = recipe.sortedPhotos.compactMap(\.photoData)
    }

    private func saveRecipe() {
        guard !isSaving else { return }
        guard canWrite else { return }
        isSaving = true
        defer { isSaving = false }

        let ingredientInputs: [RecipeIngredientInput] = ingredientDrafts.compactMap { draft in
            let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }
            let amount = Double(draft.amountText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let trimmedUnit = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            return RecipeIngredientInput(amount: amount, unit: trimmedUnit.isEmpty ? nil : trimmedUnit, name: trimmedName)
        }

        let stepInputs: [RecipeStepInput] = stepDrafts.compactMap { draft in
            let trimmedText = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return nil }
            let trimmedSection = draft.sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return RecipeStepInput(text: trimmedText, sectionTitle: trimmedSection.isEmpty ? nil : trimmedSection)
        }

        do {
            var resolvedCategories = allCategories.filter { selectedCategoryIDs.contains($0.objectID) }
            for name in pendingNewCategoryNames {
                if let category = try RecipeStore.fetchOrCreateCategory(named: name, household: household, context: context) {
                    resolvedCategories.append(category)
                }
            }

            try RecipeStore.save(
                editingRecipe: editingRecipe,
                household: household,
                title: title,
                servings: Int16(servings),
                authorSource: authorSource,
                notes: notes,
                ingredients: ingredientInputs,
                steps: stepInputs,
                categories: resolvedCategories,
                photoData: photosData,
                context: context
            )
            dismiss()
        } catch {
            context.rollback()
            print("Save recipe failed:", error)
        }
    }

    private func deleteRecipe() {
        guard canWrite else { return }
        guard let editingRecipe else { return }
        do {
            try RecipeStore.delete(editingRecipe, context: context)
            dismiss()
        } catch {
            context.rollback()
            print("Delete recipe failed:", error)
        }
    }
}

// MARK: - Draft row models

private struct IngredientDraft: Identifiable {
    let id = UUID()
    var amountText: String = ""
    var unit: String = ""
    var name: String = ""

    /// True for an untouched starter row — used so a scan result replaces a single blank row
    /// instead of leaving an empty one alongside the scanned results.
    var isBlank: Bool {
        amountText.isEmpty && unit.isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct StepDraft: Identifiable {
    let id = UUID()
    var text: String = ""
    var sectionTitle: String = ""

    var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sectionTitle.isEmpty
    }
}

// MARK: - Category chip

private struct CategoryChip: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(
                    isSelected
                        ? AppCategoryStyle.recipes.accent.opacity(0.85)
                        : Color(.secondarySystemGroupedBackground)
                )
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
