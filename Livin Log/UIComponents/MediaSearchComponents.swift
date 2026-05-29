//
//  MediaSearchComponents.swift
//  Livin Log
//

import SwiftUI

struct MediaPosterArtwork: View {
    let urlString: String
    var size: CGSize = CGSize(width: 42, height: 62)

    var body: some View {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color.blue.opacity(0.24), Color.purple.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))

            if let url = URL(string: trimmed), !trimmed.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "film.fill")
                .font(.title3)
            Text("OMDb")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }
}

struct MediaSearchResultRow: View {
    let result: OMDbSearchResult

    var body: some View {
        HStack(spacing: 12) {
            MediaPosterArtwork(urlString: result.normalizedPosterURLString)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if !result.year.isEmpty {
                        Text(result.year)
                    }
                    if let type = result.type, !type.isEmpty {
                        Text(type)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
