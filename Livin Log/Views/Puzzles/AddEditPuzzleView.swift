import SwiftUI
import CoreData
import PhotosUI
import UIKit

struct AddEditPuzzleView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    let household: Household
    let editingPuzzle: LLPuzzle?

    @State private var name = ""
    @State private var brand = ""
    @State private var selectedPiecePreset = PieceCountPreset.pieces1000
    @State private var customPieceCountText = ""
    @State private var completedAt = Date()
    @State private var notes = ""
    @State private var photoData: Data?

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingPhotoSourceDialog = false
    @State private var showingCamera = false
    @State private var showingDeleteAlert = false
    @State private var isSaving = false

    init(household: Household, editingPuzzle: LLPuzzle? = nil) {
        self.household = household
        self.editingPuzzle = editingPuzzle
    }

    private var isEditing: Bool { editingPuzzle != nil }

    private var resolvedPieceCount: Int32 {
        switch selectedPiecePreset {
        case .custom:
            return Int32(customPieceCountText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        case .unset:
            return 0
        default:
            return selectedPiecePreset.rawValue
        }
    }

    var body: some View {
        Form {
            Section("Photo") {
                photoPreview

                Button {
                    showingPhotoSourceDialog = true
                } label: {
                    Label(photoData == nil ? "Add Photo" : "Change Photo", systemImage: "photo")
                }

                if photoData != nil {
                    Button("Remove Photo", role: .destructive) {
                        photoData = nil
                    }
                }
            }

            Section("Puzzle") {
                TextField("Name", text: $name)
                TextField("Brand", text: $brand)

                Picker("Piece Count", selection: $selectedPiecePreset) {
                    ForEach(PieceCountPreset.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }

                if selectedPiecePreset == .custom {
                    TextField("Custom piece count", text: $customPieceCountText)
                        .keyboardType(.numberPad)
                }

                DatePicker("Completed", selection: $completedAt, displayedComponents: [.date])

                TextEditor(text: $notes)
                    .frame(minHeight: 110)
                    .overlay(alignment: .topLeading) {
                        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Memory / notes (optional)")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }
                    }
            }

            if isEditing {
                Section {
                    Button("Delete Puzzle", role: .destructive) {
                        showingDeleteAlert = true
                    }
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Puzzle" : "Add Puzzle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") {
                    savePuzzle()
                }
                .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .confirmationDialog("Choose Photo Source", isPresented: $showingPhotoSourceDialog) {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
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
        .sheet(isPresented: $showingCamera) {
            CameraPicker { image in
                guard let image else { return }
                photoData = image.jpegData(compressionQuality: 0.75)
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let jpeg = image.jpegData(compressionQuality: 0.75) {
                    await MainActor.run {
                        photoData = jpeg
                    }
                }
            }
        }
        .alert("Delete this puzzle?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                deletePuzzle()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
        .onAppear {
            seedIfEditing()
        }
    }

    @ViewBuilder
    private var photoPreview: some View {
        if let photoData,
           let image = UIImage(data: photoData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(.thinMaterial)
                .frame(height: 160)
                .overlay {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func seedIfEditing() {
        guard let puzzle = editingPuzzle else { return }

        name = puzzle.name ?? ""
        brand = puzzle.brand ?? ""
        completedAt = puzzle.completedAt ?? Date()
        notes = puzzle.notes ?? ""
        photoData = puzzle.photoData

        let count = puzzle.pieceCount
        if let preset = PieceCountPreset(rawValue: count), preset != .unset {
            selectedPiecePreset = preset
        } else if count > 0 {
            selectedPiecePreset = .custom
            customPieceCountText = String(count)
        } else {
            selectedPiecePreset = .unset
            customPieceCountText = ""
        }
    }

    private func savePuzzle() {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let puzzle = editingPuzzle ?? LLPuzzle(context: context)
        let now = Date()

        if puzzle.id == nil { puzzle.id = UUID() }
        if puzzle.createdAt == nil { puzzle.createdAt = now }

        puzzle.updatedAt = now
        puzzle.household = household
        puzzle.name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        puzzle.brand = trimmedBrand.isEmpty ? nil : trimmedBrand

        puzzle.pieceCount = max(0, resolvedPieceCount)
        puzzle.completedAt = completedAt

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        puzzle.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        puzzle.photoData = photoData

        do {
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            print("Save puzzle failed:", error)
        }
    }

    private func deletePuzzle() {
        guard let editingPuzzle else { return }

        context.delete(editingPuzzle)
        do {
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            print("Delete puzzle failed:", error)
        }
    }
}

private enum PieceCountPreset: Int32, CaseIterable, Identifiable {
    case unset = 0
    case pieces100 = 100
    case pieces300 = 300
    case pieces500 = 500
    case pieces750 = 750
    case pieces1000 = 1000
    case pieces1500 = 1500
    case pieces2000 = 2000
    case pieces3000 = 3000
    case custom = -1

    var id: Int32 { rawValue }

    var label: String {
        switch self {
        case .unset: return "Not set"
        case .pieces100: return "100"
        case .pieces300: return "300"
        case .pieces500: return "500"
        case .pieces750: return "750"
        case .pieces1000: return "1000"
        case .pieces1500: return "1500"
        case .pieces2000: return "2000"
        case .pieces3000: return "3000"
        case .custom: return "Custom"
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    var onImagePicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImagePicked: (UIImage?) -> Void

        init(onImagePicked: @escaping (UIImage?) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onImagePicked(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true)
            onImagePicked(image)
        }
    }
}
