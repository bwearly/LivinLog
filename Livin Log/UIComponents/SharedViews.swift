//
//  SharedViews.swift
//  Keeply
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI

enum SharedViews {

    struct SectionCard<Destination: View>: View {
        let title: String
        let subtitle: String
        let systemImage: String
        let destination: Destination

        var body: some View {
            NavigationLink {
                destination
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: systemImage)
                            .font(.title2)

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
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.thinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.quaternary)
                )
            }
            .buttonStyle(.plain)
        }
    }

    struct PlaceholderView: View {
        let title: String

        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "hammer")
                    .font(.largeTitle)

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
