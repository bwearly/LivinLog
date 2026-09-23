//
//  SyncLogger.swift
//  Livin Log
//
//  Phase 1 (CKSyncEngine migration). Mirrors SyncSpike/SpikeLogger.swift's pattern: every line
//  prefixed "[SYNC]" for easy Console.app filtering, not gated behind #if DEBUG -- this is the
//  new visibility layer replacing PersistenceController's disabled eventChangedNotification
//  observer.

import os.log

enum SyncLogger {
    private static let subsystem = "com.blakeearly.livinlog.sync"

    static let engine = Logger(subsystem: subsystem, category: "Engine")
    static let outbound = Logger(subsystem: subsystem, category: "Outbound")
    static let inbound = Logger(subsystem: subsystem, category: "Inbound")

    static func log(_ logger: Logger, _ message: String) {
        logger.log("[SYNC] \(message, privacy: .public)")
    }

    static func error(_ logger: Logger, _ message: String) {
        logger.error("[SYNC] \(message, privacy: .public)")
    }
}
