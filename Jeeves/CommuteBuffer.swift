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
