//
//  AirportDirectory.swift
//  Jeeves
//
//  IATA code → name and timezone. Bundled, not fetched.
//
//  A ticket prints every time on the local clock of its own city and never
//  prints the offset — "23:05" at BLR and "06:10" at SIN are 2h30 apart in
//  ways nothing on the page tells you. Every leave-by downstream depends on
//  resolving that, so it must work offline, instantly, and identically every
//  run. A network lookup here would put the most important arithmetic in the
//  app behind the least reliable thing in it.
//
//  The table is deliberately small: the airports this user actually flies
//  through, plus the Indian metros. An unknown code is reported as unknown —
//  never defaulted to the device's zone, which would silently produce a
//  confident and wrong departure time.
//

import Foundation

struct Airport: Equatable, Sendable {
    let iata: String
    let name: String
    /// Olson identifier — the only form that survives DST correctly.
    let timeZoneID: String

    nonisolated var timeZone: TimeZone? { TimeZone(identifier: timeZoneID) }
}

enum AirportDirectory {

    /// Known airports, keyed by uppercase IATA.
    nonisolated static let all: [String: Airport] = [
        // The user's own routes
        "BLR": Airport(iata: "BLR", name: "Kempegowda International", timeZoneID: "Asia/Kolkata"),
        "SIN": Airport(iata: "SIN", name: "Changi", timeZoneID: "Asia/Singapore"),
        "DPS": Airport(iata: "DPS", name: "Ngurah Rai", timeZoneID: "Asia/Makassar"),
        "PBH": Airport(iata: "PBH", name: "Paro", timeZoneID: "Asia/Thimphu"),

        // Indian metros
        "BOM": Airport(iata: "BOM", name: "Chhatrapati Shivaji Maharaj", timeZoneID: "Asia/Kolkata"),
        "DEL": Airport(iata: "DEL", name: "Indira Gandhi International", timeZoneID: "Asia/Kolkata"),
        "MAA": Airport(iata: "MAA", name: "Chennai International", timeZoneID: "Asia/Kolkata"),
        "HYD": Airport(iata: "HYD", name: "Rajiv Gandhi International", timeZoneID: "Asia/Kolkata"),
        "CCU": Airport(iata: "CCU", name: "Netaji Subhas Chandra Bose", timeZoneID: "Asia/Kolkata"),
        "GOI": Airport(iata: "GOI", name: "Goa Dabolim", timeZoneID: "Asia/Kolkata"),
        "GOX": Airport(iata: "GOX", name: "Manohar International", timeZoneID: "Asia/Kolkata"),
        "COK": Airport(iata: "COK", name: "Cochin International", timeZoneID: "Asia/Kolkata"),
        "IXE": Airport(iata: "IXE", name: "Mangaluru International", timeZoneID: "Asia/Kolkata"),

        // Common regional hubs
        "BKK": Airport(iata: "BKK", name: "Suvarnabhumi", timeZoneID: "Asia/Bangkok"),
        "DMK": Airport(iata: "DMK", name: "Don Mueang", timeZoneID: "Asia/Bangkok"),
        "KUL": Airport(iata: "KUL", name: "Kuala Lumpur International", timeZoneID: "Asia/Kuala_Lumpur"),
        "CGK": Airport(iata: "CGK", name: "Soekarno–Hatta", timeZoneID: "Asia/Jakarta"),
        "HKG": Airport(iata: "HKG", name: "Hong Kong International", timeZoneID: "Asia/Hong_Kong"),
        "DXB": Airport(iata: "DXB", name: "Dubai International", timeZoneID: "Asia/Dubai"),
        "AUH": Airport(iata: "AUH", name: "Zayed International", timeZoneID: "Asia/Dubai"),
        "DOH": Airport(iata: "DOH", name: "Hamad International", timeZoneID: "Asia/Qatar"),
        "CMB": Airport(iata: "CMB", name: "Bandaranaike International", timeZoneID: "Asia/Colombo"),
        "KTM": Airport(iata: "KTM", name: "Tribhuvan International", timeZoneID: "Asia/Kathmandu"),
        "MLE": Airport(iata: "MLE", name: "Velana International", timeZoneID: "Indian/Maldives"),
        "LHR": Airport(iata: "LHR", name: "Heathrow", timeZoneID: "Europe/London"),
        "CDG": Airport(iata: "CDG", name: "Charles de Gaulle", timeZoneID: "Europe/Paris"),
        "JFK": Airport(iata: "JFK", name: "John F. Kennedy", timeZoneID: "America/New_York"),
        "SFO": Airport(iata: "SFO", name: "San Francisco International", timeZoneID: "America/Los_Angeles"),
        "SYD": Airport(iata: "SYD", name: "Kingsford Smith", timeZoneID: "Australia/Sydney"),
        "NRT": Airport(iata: "NRT", name: "Narita International", timeZoneID: "Asia/Tokyo"),
        "HND": Airport(iata: "HND", name: "Haneda", timeZoneID: "Asia/Tokyo"),
    ]

    /// Looks a code up. Case- and whitespace-tolerant because tickets are not.
    nonisolated static func airport(_ code: String) -> Airport? {
        let key = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return all[key]
    }

    /// The zone for a code, or nil when the code is unknown.
    ///
    /// Returning nil rather than `.current` is the whole point: an unknown
    /// airport must surface as unknown. Defaulting to the phone's zone would
    /// read every foreign departure in IST and be wrong by hours with no
    /// visible symptom.
    nonisolated static func timeZone(_ code: String) -> TimeZone? {
        airport(code)?.timeZone
    }

    /// Human name, falling back to the bare code so a label is never empty.
    nonisolated static func name(_ code: String) -> String {
        airport(code)?.name ?? code.uppercased()
    }

    nonisolated static func isKnown(_ code: String) -> Bool { airport(code) != nil }
}
