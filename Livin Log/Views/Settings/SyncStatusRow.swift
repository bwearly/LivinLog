//
//  SyncStatusRow.swift
//  Livin Log
//
//  Settings > iCloud & Sync: one friendly status line plus "Last synced <relative time>".
//  Backed by SyncStatus (engine events + NWPathMonitor) and the CKAccountStatus SettingsView
//  already loads.

import CloudKit
import SwiftUI

struct SyncStatusRow: View {
    /// nil until SettingsView's account-status check has returned.
    let accountStatus: CKAccountStatus?

    @ObservedObject private var status = SyncStatus.shared

    private var isICloudUnavailable: Bool {
        switch accountStatus {
        case .noAccount, .restricted, .temporarilyUnavailable: return true
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(statusText)
            Spacer()
            if status.isSyncing && !status.isOffline && !isICloudUnavailable {
                ProgressView()
            }
        }

        // Re-renders the relative time periodically while Settings is open.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Text(lastSyncedText)
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
    }

    private var statusText: String {
        if isICloudUnavailable { return "iCloud unavailable" }
        if status.isOffline { return "Offline, changes will sync later" }
        if status.isSyncing { return "Syncing…" }
        return "Up to date"
    }

    private var iconName: String {
        if isICloudUnavailable { return "exclamationmark.icloud" }
        if status.isOffline { return "icloud.slash" }
        if status.isSyncing { return "arrow.triangle.2.circlepath.icloud" }
        return "checkmark.icloud"
    }

    private var iconColor: Color {
        if isICloudUnavailable { return .red }
        if status.isOffline { return .orange }
        if status.isSyncing { return .blue }
        return .green
    }

    private var lastSyncedText: String {
        guard let lastSyncedAt = status.lastSyncedAt else { return "Not synced yet" }
        return "Last synced \(lastSyncedAt.formatted(.relative(presentation: .named)))"
    }
}
