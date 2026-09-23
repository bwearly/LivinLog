//
//  SpikeLogger.swift
//  SyncSpike
//
//  Every line goes through here so it's easy to grep "[SPIKE]" in Console.app.
//  Not gated behind #if DEBUG on purpose.

import os.log

enum SpikeLogger {
    private static let subsystem = "com.blakeearly.SyncSpike"

    static let engine = Logger(subsystem: subsystem, category: "Engine")
    static let share = Logger(subsystem: subsystem, category: "Share")
    static let ui = Logger(subsystem: subsystem, category: "UI")

    static func log(_ logger: Logger, _ message: String) {
        logger.log("[SPIKE] \(message, privacy: .public)")
    }

    static func error(_ logger: Logger, _ message: String) {
        logger.error("[SPIKE] \(message, privacy: .public)")
    }
}
