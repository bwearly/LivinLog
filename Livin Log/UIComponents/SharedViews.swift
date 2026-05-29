//
//  SharedViews.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI

enum AppCategoryStyle {
    case movies
    case tvShows
    case books
    case quotes
    case analytics
    case dates
    case puzzles
    case settings

    var accent: Color {
        switch self {
        case .movies: return .orange
        case .tvShows: return .cyan
        case .books: return .indigo
        case .quotes: return .pink
        case .analytics: return .purple
        case .dates: return .green
        case .puzzles: return .teal
        case .settings: return .blue
        }
    }

    var secondaryAccent: Color {
        switch self {
        case .movies: return .red
        case .tvShows: return .blue
        case .books: return .purple
        case .quotes: return .orange
        case .analytics: return .pink
        case .dates: return .mint
        case .puzzles: return .yellow
        case .settings: return .cyan
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.22), secondaryAccent.opacity(0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension View {
    func subtleCategoryRowCard(
        style: AppCategoryStyle,
        horizontalPadding: CGFloat = 10,
        verticalPadding: CGFloat = 10
    ) -> some View {
        modifier(SharedViews.SubtleRowCardModifier(
            style: style,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        ))
    }
}

enum SharedViews {

    struct SectionCard<Destination: View>: View {
        let title: String
        let subtitle: String
        let systemImage: String
        let destination: Destination
        let style: AppCategoryStyle

        init(
            title: String,
            subtitle: String,
            systemImage: String,
            style: AppCategoryStyle = .settings,
            destination: Destination
        ) {
            self.title = title
            self.subtitle = subtitle
            self.systemImage = systemImage
            self.style = style
            self.destination = destination
        }

        var body: some View {
            NavigationLink {
                destination
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: systemImage)
                            .font(.title2)
                            .foregroundStyle(style.accent)
                            .frame(width: 34, height: 34)
                            .background(style.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Text(title)
                            .font(.headline)
                    }

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(height: 110)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.thinMaterial)
                        style.gradient
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(style.accent.opacity(0.22))
                )
            }
            .buttonStyle(.plain)
        }
    }

    struct AccentSectionHeader: View {
        let title: String
        let systemImage: String
        let style: AppCategoryStyle

        var body: some View {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(style.accent)
                .textCase(.uppercase)
        }
    }

    struct SoftEmptyState: View {
        let title: String
        let systemImage: String
        let style: AppCategoryStyle
        var description: String?

        var body: some View {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(style.accent)
                    .frame(width: 58, height: 58)
                    .background(style.gradient, in: Circle())

                Text(title)
                    .font(.headline)

                if let description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }


    struct AccentPill: View {
        let text: String
        let systemImage: String?
        let style: AppCategoryStyle

        init(_ text: String, systemImage: String? = nil, style: AppCategoryStyle) {
            self.text = text
            self.systemImage = systemImage
            self.style = style
        }

        var body: some View {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.semibold))
                }

                Text(text)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(style.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(style.accent.opacity(0.12), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(style.accent.opacity(0.2), lineWidth: 0.5)
            )
        }
    }

    struct AccentIconBadge: View {
        let systemImage: String
        let style: AppCategoryStyle

        var body: some View {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(style.accent)
                .frame(width: 22, height: 22)
                .background(style.accent.opacity(0.12), in: Circle())
        }
    }

    struct SubtleRowCardModifier: ViewModifier {
        let style: AppCategoryStyle
        var horizontalPadding: CGFloat = 10
        var verticalPadding: CGFloat = 10

        func body(content: Content) -> some View {
            content
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, horizontalPadding)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground).opacity(0.82))
                )
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(style.accent.opacity(0.72))
                        .frame(width: 3)
                        .padding(.vertical, 12)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style.accent.opacity(0.16), lineWidth: 0.75)
                )
        }
    }

    struct PlaceholderView: View {
        let title: String

        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "hammer")
                    .font(.largeTitle)
                    .foregroundStyle(AppCategoryStyle.settings.accent)
                    .frame(width: 64, height: 64)
                    .background(AppCategoryStyle.settings.gradient, in: Circle())

                Text("\(title) coming soon")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
