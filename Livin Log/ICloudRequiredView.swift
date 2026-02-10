//
//  ICloudRequiredView.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//


import SwiftUI

struct ICloudRequiredView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 46))

            Text("iCloud Required")
                .font(.title2).bold()

            Text("Livin Log uses iCloud to sync and share your household library. Please sign into iCloud on this device, then tap Retry.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button("Retry") {
                onRetry()
            }
            .buttonStyle(.borderedProminent)

            Text("Settings → Apple ID → iCloud")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding()
    }
}
