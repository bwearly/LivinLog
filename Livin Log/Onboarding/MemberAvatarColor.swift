//
//  MemberAvatarColor.swift
//  Livin Log
//
//  Phase 3a onboarding. The small fixed palette stamped into HouseholdMember.avatar (a plain
//  color-name token, not image data -- see the Phase 3a plan) and rendered anywhere a member
//  needs a lightweight visual identity.

import SwiftUI

enum MemberAvatarColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        }
    }

    static var `default`: MemberAvatarColor { .blue }

    /// Falls back to `.default` for nil/unrecognized values (e.g. an older member row with no
    /// avatar stamped yet) rather than failing -- avatar is decorative, never load-bearing.
    static func from(_ rawValue: String?) -> MemberAvatarColor {
        rawValue.flatMap(MemberAvatarColor.init(rawValue:)) ?? .default
    }
}

/// A row of tappable color swatches. Used by the onboarding "Who are you?" and "Add member"
/// steps to pick `HouseholdMember.avatar`.
struct MemberAvatarColorPicker: View {
    @Binding var selection: MemberAvatarColor

    var body: some View {
        HStack(spacing: 12) {
            ForEach(MemberAvatarColor.allCases) { option in
                Button {
                    selection = option
                } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if selection == option {
                                Circle()
                                    .strokeBorder(Color.primary, lineWidth: 2)
                                    .padding(2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.rawValue.capitalized)
                .accessibilityAddTraits(selection == option ? [.isSelected] : [])
            }
        }
    }
}

/// A small filled circle badge showing a member's initial over their avatar color. Used in the
/// onboarding roster and anywhere else a compact member identity is useful.
struct MemberAvatarBadge: View {
    let name: String
    let avatar: String?
    var diameter: CGFloat = 36

    private var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)?.uppercased() ?? "?"
    }

    var body: some View {
        Circle()
            .fill(MemberAvatarColor.from(avatar).color.opacity(0.85))
            .frame(width: diameter, height: diameter)
            .overlay {
                Text(initial)
                    .font(.system(size: diameter * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
