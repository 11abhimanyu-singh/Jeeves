//
//  DiagnosticsSync.swift
//  Jeeves
//
//  Mirrors the plan-generation diagnostics to a JSON file in the app's iCloud
//  Drive folder, so they sync to the user's Mac for analysis without tethering
//  the phone. Best-effort and resilient: if iCloud Documents isn't available
//  (entitlement not added, or not signed into iCloud) the ubiquity URL is nil
//  and this simply does nothing — never a crash. The file lands on a Mac
//  (same Apple ID) at:
//    ~/Library/Mobile Documents/iCloud~abhimanyusingh~me~Jeeves/Documents/jeeves-diagnostics.json
//

import Foundation

enum DiagnosticsSync {
    private static let containerID = "iCloud.abhimanyusingh.me.Jeeves"
    private static let fileName = "jeeves-diagnostics.json"

    /// A plain, Sendable snapshot of one log row (so it can cross to a
    /// background task without touching the SwiftData model).
    struct LogEntry: Codable, Sendable {
        var startedAt: Date
        var durationMs: Int
        var claudeMs: Int
        var commuteMs: Int
        var trigger: String
        var outcome: String
        var retryCount: Int
        var errorClass: String?
    }

    struct Snapshot: Codable, Sendable {
        var exportedAt: Date
        var count: Int
        var logs: [LogEntry]
    }

    static func entries(from logs: [PlanGenerationLog]) -> [LogEntry] {
        logs.sorted { $0.startedAt > $1.startedAt }.map {
            LogEntry(startedAt: $0.startedAt, durationMs: $0.durationMs, claudeMs: $0.claudeMs,
                     commuteMs: $0.commuteMs, trigger: $0.trigger.rawValue, outcome: $0.outcome.rawValue,
                     retryCount: $0.retryCount, errorClass: $0.errorClass)
        }
    }

    /// Write the snapshot off the main thread (the ubiquity-URL lookup can block).
    /// `now` is injected so the encoding is deterministic in tests.
    static func write(_ entries: [LogEntry], now: Date = Date()) {
        Task.detached(priority: .utility) {
            guard let docs = documentsURL() else { return }
            let snapshot = Snapshot(exportedAt: now, count: entries.count, logs: entries)
            guard let data = try? encoder.encode(snapshot) else { return }
            let url = docs.appendingPathComponent(fileName)
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                try? data.write(to: target, options: .atomic)
            }
        }
    }

    private static func documentsURL() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else { return nil }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
