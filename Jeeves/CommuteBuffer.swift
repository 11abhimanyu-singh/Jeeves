//
//  CommuteBuffer.swift
//  Jeeves
//
//  Parking is time you spend, and only on the way there.
//
//  A measured Maps duration is door-to-kerb: it ends when the car stops, not
//  when you're inside. Arriving somewhere costs another ten minutes of finding
//  a space and walking in. Coming home doesn't — you park and you're there.
//
//  Kept apart from TravelSegment.bufferMinutes, which is the trip layer's
//  contingency on a leave-by chain for flights and long drives. This is the
//  day plan's commute block, and conflating the two would double-count.
//

import Foundation

enum CommuteBuffer {
    /// Finding a space and walking in.
    static let parkingMinutes = 10

    /// Route keys arrive as "From→To" (and occasionally "From → To"). Only the
    /// destination decides: anywhere that isn't home needs parking.
    static func needsParking(route: String) -> Bool {
        destination(of: route).map { !isHome($0) } ?? false
    }

    /// The measured minutes plus parking where it applies.
    static func doorToDoor(minutes: Int, route: String) -> Int {
        minutes + (needsParking(route: route) ? parkingMinutes : 0)
    }

    /// The half after the arrow, trimmed. Nil when the key isn't a route.
    static func destination(of route: String) -> String? {
        for sep in ["→", "->", " to "] {
            if let r = route.range(of: sep, options: .caseInsensitive) {
                let tail = route[r.upperBound...].trimmingCharacters(in: .whitespaces)
                return tail.isEmpty ? nil : tail
            }
        }
        return nil
    }

    /// Which measured route a plan block describes, if any. Block titles are
    /// prose ("Commute Home → Gym", "Commute to gym", "Commute home") while
    /// estimate keys are compact ("Home→Gym"), so match on the meaningful
    /// words rather than the exact string.
    static func matchRoute(blockTitle: String, in estimates: [String: Int]) -> (route: String, minutes: Int)? {
        let title = blockTitle.lowercased()
        guard title.contains("commute") || title.contains("drive") || title.contains("travel") else { return nil }
        var best: (route: String, minutes: Int, score: Int)?
        for (route, minutes) in estimates {
            guard let to = destination(of: route) else { continue }
            let from = String(route[route.startIndex..<(route.range(of: "→")?.lowerBound
                ?? route.range(of: "->")?.lowerBound ?? route.endIndex)])
            // The destination must be named; the origin adds confidence.
            guard mentions(title, to) else { continue }
            let score = 1 + (mentions(title, from) ? 1 : 0)
            if score > (best?.score ?? 0) { best = (route, minutes, score) }
        }
        return best.map { ($0.route, $0.minutes) }
    }

    /// What a block for this route must be AT LEAST. Commute time and parking
    /// are physical facts, not preferences — a plan that shaves either one is
    /// a plan that makes you late.
    static func minimumMinutes(route: String, measured: Int) -> Int {
        measured + (needsParking(route: route) ? parkingMinutes : 0)
    }

    private static func mentions(_ title: String, _ place: String) -> Bool {
        let p = place.trimmingCharacters(in: .whitespaces).lowercased()
        guard p.count >= 3 else { return false }
        if title.contains(p) { return true }
        // "Home → Gym" vs "Commute to gym": match on the distinctive word.
        return p.split(separator: " ").contains { $0.count >= 3 && title.contains($0.lowercased()) }
    }

    /// "Home", "home in Indiranagar", or a saved home address all count.
    static func isHome(_ place: String, homeAddress: String = "") -> Bool {
        let p = place.trimmingCharacters(in: .whitespaces).lowercased()
        if p == "home" || p.hasPrefix("home ") || p.hasSuffix(" home") { return true }
        if p.contains("home") { return true }
        if !homeAddress.isEmpty,
           ChatToolExecutor.sharesPlaceWord(place, homeAddress) { return true }
        return false
    }
}
