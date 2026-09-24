//
//  SyncStatus.swift
//  Livin Log
//
//  Settings cleanup: the one friendly sync status line in Settings > iCloud & Sync. Fed from
//  SyncController's existing CKSyncEngine event switch (will/did fetch/send) plus an
//  NWPathMonitor for "Offline" -- CKSyncEngine's `didFetchChanges` carries no error, so a failed
//  fetch is otherwise invisible and can't be used to infer being offline.

import Combine
import Foundation
import Network

@MainActor
final class SyncStatus: ObservableObject {

    static let shared = SyncStatus()

    /// True only while the current network path is unsatisfied.
    @Published private(set) var isOffline = false
    /// A fetch or send is in flight on either engine, or local changes are still queued to send.
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?

    private var inFlightOperations: Set<String> = []
    private var hasPendingChanges = false
    private let pathMonitor = NWPathMonitor()

    private static let lastSyncedAtKey = "ll_last_synced_at"

    private init() {
        lastSyncedAt = UserDefaults.standard.object(forKey: Self.lastSyncedAtKey) as? Date

        // `@Sendable` keeps this closure out of the module's default MainActor isolation --
        // NWPathMonitor calls it on its own queue, then we hop back to the main actor.
        // Goes through `shared` rather than capturing `self`, which would be a Sendable-capture
        // error in Swift 6 mode. `shared` is the only instance (private init).
        pathMonitor.pathUpdateHandler = { @Sendable path in
            let offline = path.status != .satisfied
            Task { @MainActor in SyncStatus.shared.isOffline = offline }
        }
        pathMonitor.start(queue: DispatchQueue(label: "SyncStatus.pathMonitor"))
    }

    func operationStarted(_ key: String) {
        inFlightOperations.insert(key)
        recompute()
    }

    func operationFinished(_ key: String, markSynced: Bool) {
        inFlightOperations.remove(key)
        if markSynced {
            let now = Date()
            lastSyncedAt = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncedAtKey)
        }
        recompute()
    }

    func setHasPendingChanges(_ value: Bool) {
        hasPendingChanges = value
        recompute()
    }

    private func recompute() {
        let syncing = !inFlightOperations.isEmpty || hasPendingChanges
        if syncing != isSyncing { isSyncing = syncing }
    }
}
