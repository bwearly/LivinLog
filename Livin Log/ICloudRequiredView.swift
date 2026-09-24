//
//  ICloudRequiredView.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//


import SwiftUI

struct ICloudRequiredView: View {
    var icon: String = "icloud.slash"
    var title: String = "iCloud Required"
    var message: String = "Livin Log uses iCloud to sync and share your household library. Please sign into iCloud on this device, then tap Retry."
    var footnote: String? = "Settings → Apple ID → iCloud"
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46))

            Text(title)
                .font(.title2).bold()

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button("Retry") {
                onRetry()
            }
            .buttonStyle(.borderedProminent)

            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .padding()
    }
}
