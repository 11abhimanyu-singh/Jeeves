//
//  DataBackup.swift
//  Jeeves
//
//  Copies the whole SwiftData store (every table — check-ins, plans, routine,
//  books, events, chat, AND the diagnostics logs) into the app's iCloud Drive
//  folder, so a complete snapshot syncs to the user's Mac for backup/analysis
//  without tethering. The store is a SQLite file; copying store + -wal + -shm
//  together gives a consistent, readable snapshot. Best-effort and resilient:
//  no-op if iCloud Documents isn't available. Runs off the main thread.
//
//  On a Mac (same Apple ID) the snapshot lands at:
//    ~/Library/Mobile Documents/iCloud~abhimanyusingh~me~Jeeves/Documents/backup/
//

import Foundation

enum DataBackup {
    /// The SwiftData default store lives in Application Support.
    private static let storeName = "default.store"
    private static let companionSuffixes = ["", "-wal", "-shm"]

    static func writeToICloud(now: Date = Date()) {
        Task.detached(priority: .utility) {
            guard let docs = DiagnosticsSync.documentsURL() else { return }
            let fm = FileManager.default
            guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

            let backupDir = docs.appendingPathComponent("backup", isDirectory: true)
            try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

            for suffix in companionSuffixes {
                let source = appSupport.appendingPathComponent("\(storeName)\(suffix)")
                guard fm.fileExists(atPath: source.path) else { continue }
                let destination = backupDir.appendingPathComponent("jeeves.store\(suffix)")
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: destination,
                                               options: .forReplacing, error: &coordinationError) { src, dst in
                    try? fm.removeItem(at: dst)
                    try? fm.copyItem(at: src, to: dst)
                }
            }

            // A tiny manifest so it's obvious when the snapshot was taken.
            let stamp = ISO8601DateFormatter().string(from: now)
            try? Data("{\"backedUpAt\":\"\(stamp)\"}".utf8)
                .write(to: backupDir.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }
}
