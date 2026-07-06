//
//  HeartbeatLogger.swift
//  Livin Log
//

import Foundation

/// Task 4 diagnostic: two independent once-per-second heartbeats, started at app launch and
/// kept alive for the process lifetime, so a stalled `share()` completion handler can be
/// triangulated from console logs alone (no live debugger session required):
///
/// - `Heartbeat/Main` runs on a `@MainActor`-isolated `Task`. If it stops ticking, the main
///   actor is blocked by something synchronous.
/// - `Heartbeat/Background` runs on a fully detached `Task`, not MainActor-isolated. If it
///   keeps ticking while `Heartbeat/Main` stops, the block is specific to the main actor. If
///   both stop, the whole process is wedged (not just the main actor).
///
/// Pure logging; no behavior change to sharing or Core Data.
enum HeartbeatLogger {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true

        Task { @MainActor in
            var tick = 0
            while true {
                tick += 1
                print("💓 [Heartbeat/Main] tick=\(tick) at=\(ISO8601DateFormatter().string(from: Date()))")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        Task.detached {
            var tick = 0
            while true {
                tick += 1
                print("💓 [Heartbeat/Background] tick=\(tick) at=\(ISO8601DateFormatter().string(from: Date()))")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
