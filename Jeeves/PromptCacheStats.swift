//
//  PromptCacheStats.swift
//  Jeeves
//
//  Did prompt caching actually work? Not "did we set the parameter" — did the
//  API serve tokens from cache. Those are different questions, and the iCloud
//  export spent days looking healthy because the code measured the first one
//  and reported it as the second.
//
//  So: read the counts back out of the API's own `usage` block and keep a
//  rolling daily tally the Health screen can show. A cache that silently stops
//  hitting (a tool schema edit, a stray timestamp in the cached prefix) is
//  invisible otherwise — the calls still succeed, they just cost 1.25x instead
//  of 0.1x forever.
//

import Foundation

enum PromptCacheStats {
    private static let dayKey = "jeeves.cache.day"
    private static let readKey = "jeeves.cache.read"
    private static let writeKey = "jeeves.cache.write"
    private static let plainKey = "jeeves.cache.uncached"
    private static let callsKey = "jeeves.cache.calls"

    struct Day: Sendable {
        var read = 0        // tokens served from cache (0.1x price)
        var write = 0       // tokens written to cache (1.25x price)
        var uncached = 0    // ordinary input tokens (1.0x price)
        var calls = 0

        /// Share of the cacheable prefix that actually came from cache.
        /// nil until there's something to divide by.
        var hitRate: Double? {
            let total = read + write
            return total > 0 ? Double(read) / Double(total) : nil
        }

        /// What the cached traffic cost versus sending it uncached, using the
        /// published multipliers (write 1.25x, read 0.1x). Below 1.0 is a win.
        var costRatio: Double? {
            let total = read + write
            guard total > 0 else { return nil }
            let cached = Double(write) * 1.25 + Double(read) * 0.1
            return cached / Double(total)
        }
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Roll the tally over at midnight so the Health screen reads "today",
    /// not "since install" — a lifetime average would hide a cache that broke
    /// this morning.
    nonisolated static func record(read: Int, write: Int, uncached: Int) {
        let d = UserDefaults.standard
        let day = today()
        if d.string(forKey: dayKey) != day {
            d.set(day, forKey: dayKey)
            d.set(0, forKey: readKey)
            d.set(0, forKey: writeKey)
            d.set(0, forKey: plainKey)
            d.set(0, forKey: callsKey)
        }
        d.set(d.integer(forKey: readKey) + read, forKey: readKey)
        d.set(d.integer(forKey: writeKey) + write, forKey: writeKey)
        d.set(d.integer(forKey: plainKey) + uncached, forKey: plainKey)
        d.set(d.integer(forKey: callsKey) + 1, forKey: callsKey)
    }

    nonisolated static func todayStats() -> Day {
        let d = UserDefaults.standard
        guard d.string(forKey: dayKey) == today() else { return Day() }
        return Day(read: d.integer(forKey: readKey),
                   write: d.integer(forKey: writeKey),
                   uncached: d.integer(forKey: plainKey),
                   calls: d.integer(forKey: callsKey))
    }

    /// One line for the digest. Deliberately says "not caching" rather than
    /// staying silent when every call is a write — silence reads as fine.
    nonisolated static func summary() -> String {
        let s = todayStats()
        guard s.calls > 0 else { return "no model calls yet today" }
        guard let hit = s.hitRate else {
            return "\(s.calls) call\(s.calls == 1 ? "" : "s"), nothing cacheable"
        }
        let pct = Int((hit * 100).rounded())
        let saved = s.costRatio.map { " · \(Int(((1 - $0) * 100).rounded()))% cheaper on the prefix" } ?? ""
        return "\(pct)% of prefix from cache over \(s.calls) call\(s.calls == 1 ? "" : "s")\(saved)"
    }
}
