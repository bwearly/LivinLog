//
//  GenrePickerView.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//


import SwiftUI

struct GenrePickerView: View {
    let title: String
    let allGenres: [String]
    @Binding var selected: Set<String>

    var body: some View {
        List {
            ForEach(allGenres, id: \.self) { genre in
                Button {
                    toggle(genre)
                } label: {
                    HStack {
                        Text(genre)
                        Spacer()
                        if selected.contains(genre) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ genre: String) {
        if selected.contains(genre) {
            selected.remove(genre)
        } else {
            selected.insert(genre)
        }
    }
}

