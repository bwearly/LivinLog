//
//  RecipeOCR.swift
//  Livin Log
//
//  Created by Blake Early on 8/21/26.
//
//  On-device Vision OCR for the "Scan a Recipe Photo" entry point in AddEditRecipeView. This is
//  the app's first use of the Vision framework — no cloud call, no API key, nothing leaves the
//  device. It recognizes raw text, then applies a deliberately simple shape-based heuristic
//  (not NLP) to guess which lines are ingredients vs. instructions. Accuracy is expected to be
//  imperfect, especially on handwriting or multi-column layouts — the result always lands back
//  in AddEditRecipeView's normal editable fields for the user to review before Save, never
//  written to Core Data directly from here.

import UIKit
import Vision

struct RecipeOCRResult {
    var titleGuess: String?
    var ingredientLines: [String]
    var instructionLines: [String]
}

enum RecipeOCR {
    enum OCRError: LocalizedError {
        case noImage
        var errorDescription: String? {
            "Couldn't read that image."
        }
    }

    /// Runs Vision text recognition against the given image and returns recognized lines in
    /// top-to-bottom reading order. Callers should pass the original picked/captured image —
    /// not a recompressed storage copy — since JPEG requantization can soften text edges Vision
    /// relies on (see Part 2 investigation).
    static func recognizeText(in image: UIImage) async throws -> [String] {
        guard let cgImage = image.cgImage else { throw OCRError.noImage }

        // Vision does not auto-correct orientation the way SwiftUI's Image(uiImage:) does —
        // a portrait photo handed to VNImageRequestHandler without this would recognize text
        // sideways/upside-down and return garbage.
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                // VNRecognizedTextObservation.boundingBox is normalized with a bottom-left
                // origin, so descending y reconstructs top-to-bottom reading order.
                let ordered = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
                let lines = ordered.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Recognizable unit words used both to classify a line as a likely ingredient and, in
    /// `parseIngredientLine`, to split a leading unit token off the ingredient name.
    private static let unitWords: Set<String> = [
        "cup", "cups", "tsp", "tbsp", "teaspoon", "teaspoons", "tablespoon", "tablespoons",
        "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds", "g", "gram", "grams",
        "kg", "ml", "l", "liter", "liters", "pinch", "dash", "clove", "cloves", "can", "cans",
        "stick", "sticks", "package", "packages", "pkg", "quart", "quarts", "pint", "pints",
        "slice", "slices", "head", "heads", "bunch"
    ]

    /// Recipe card section headers — never an ingredient or instruction line in their own
    /// right, so they're dropped rather than classified. Matched against the whole line
    /// (case-insensitive, trailing colon ignored), not just the leading word.
    private static let sectionLabelLines: Set<String> = [
        "ingredients", "instructions", "directions", "method", "steps", "preparation",
        "directions for use", "what you need", "what you'll need"
    ]

    private static func isSectionLabel(_ line: String) -> Bool {
        let normalized = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return sectionLabelLines.contains(normalized)
    }

    private static let imperativeVerbs: Set<String> = [
        "mix", "add", "bake", "stir", "preheat", "combine", "whisk", "pour", "fold", "chop",
        "slice", "dice", "heat", "cook", "simmer", "boil", "blend", "beat", "season", "serve",
        "let", "place", "remove", "cover", "reduce", "spread", "sprinkle", "garnish",
        "transfer", "cut", "melt", "chill", "refrigerate", "freeze", "drain", "rinse",
        "toss", "arrange", "top", "layer", "bring", "set", "line", "grease", "roll", "knead",
        "taste", "brown", "sauté", "saute", "whip", "spoon", "flip", "rest", "assemble"
    ]

    /// Splits recognized lines into a title guess, candidate ingredients, and candidate
    /// instructions. This is shape-based heuristics only (line length, leading token), not NLP —
    /// deliberately simple per the investigation, and expected to misfire on real-world recipe
    /// cards. Ambiguous lines default to ingredients, since a stray line sitting in the
    /// ingredient list is a cheaper mistake for the user to notice and move than the reverse.
    static func classify(lines: [String]) -> RecipeOCRResult {
        var titleGuess: String?
        var ingredients: [String] = []
        var instructions: [String] = []

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // Section labels like "Ingredients"/"Instructions" are common on printed recipe
            // cards and would otherwise fall through to the short-line ingredient default (or
            // get picked as the title guess) — found by testing against a real rendered card,
            // not anticipated in the original heuristic design. Drop them outright.
            if isSectionLabel(line) { continue }

            // The first short, non-numeric-leading line near the top is a reasonable title guess.
            if titleGuess == nil, index < 3, line.count <= 60, !startsWithQuantity(line) {
                titleGuess = line
                continue
            }

            let words = line.split(separator: " ")
            let wordCount = words.count
            let firstWord = words.first.map(String.init)?
                .lowercased()
                .trimmingCharacters(in: .punctuationCharacters) ?? ""

            let leadsWithQuantity = startsWithQuantity(line)
            let leadsWithUnit = unitWords.contains(firstWord)
            let leadsWithVerb = imperativeVerbs.contains(firstWord)
            let isShort = wordCount <= 10
            let looksLikeSentence = wordCount > 6 && (line.contains(".") || line.contains(","))

            if leadsWithVerb || looksLikeSentence || (!isShort && !leadsWithQuantity && !leadsWithUnit) {
                instructions.append(line)
            } else {
                // Covers leadsWithQuantity, leadsWithUnit, short-and-ambiguous — all default here.
                ingredients.append(line)
            }
        }

        return RecipeOCRResult(titleGuess: titleGuess, ingredientLines: ingredients, instructionLines: instructions)
    }

    /// Best-effort split of one ingredient line into `amount`/`unit`/`name`. Handles a leading
    /// decimal ("2"), a simple fraction ("1/2"), a unicode fraction ("½"), or a mixed number
    /// ("1 1/2"), followed by an optional recognized unit word. Falls back to the raw line as
    /// `name` with an empty amount/unit when no leading quantity is recognized, rather than
    /// guessing wrong silently — the raw text is always preserved for the user to fix by hand.
    static func parseIngredientLine(_ rawLine: String) -> (amountText: String, unit: String, name: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        var tokens = line.split(separator: " ").map(String.init)
        guard !tokens.isEmpty, let firstValue = numericValue(of: tokens[0]) else {
            return ("", "", line)
        }
        tokens.removeFirst()

        var amount = firstValue
        if let next = tokens.first, let fractionValue = fractionValue(of: next) {
            amount += fractionValue
            tokens.removeFirst()
        }

        var unit = ""
        if let next = tokens.first {
            let cleaned = next.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if unitWords.contains(cleaned) {
                unit = next.trimmingCharacters(in: .punctuationCharacters)
                tokens.removeFirst()
            }
        }

        let name = tokens.joined(separator: " ")
        return (formattedRecipeAmount(amount), unit, name.isEmpty ? line : name)
    }

    // MARK: - Numeric token parsing

    private static let unicodeFractions: [Character: Double] = [
        "¼": 0.25, "½": 0.5, "¾": 0.75,
        "⅓": 1.0 / 3.0, "⅔": 2.0 / 3.0,
        "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875
    ]

    private static func startsWithQuantity(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if first.isNumber { return true }
        return unicodeFractions[first] != nil
    }

    private static func numericValue(of token: String) -> Double? {
        if token.count == 1, let ch = token.first, let value = unicodeFractions[ch] {
            return value
        }
        if token.contains("/") {
            return fractionValue(of: token)
        }
        return Double(token)
    }

    private static func fractionValue(of token: String) -> Double? {
        if token.count == 1, let ch = token.first, let value = unicodeFractions[ch] {
            return value
        }
        let parts = token.split(separator: "/")
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator != 0 else {
            return nil
        }
        return numerator / denominator
    }
}

private extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
