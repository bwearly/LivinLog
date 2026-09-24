//
//  JoiningHouseholdView.swift
//  Livin Log
//
//  Phase 3b: shown for AppState.Route.joiningHousehold, while accepting an incoming CKShare and
//  waiting for the shared engine to fetch the newly-joined household.

import SwiftUI

struct JoiningHouseholdView: View {
    let householdName: String?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(householdName.map { "Joining \($0)…" } ?? "Joining household…")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}
