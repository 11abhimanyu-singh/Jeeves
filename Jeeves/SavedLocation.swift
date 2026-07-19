//
//  SavedLocation.swift
//  Jeeves
//
//  A place the user routes to/from, set up once (PRD §5.4). Each carries an
//  address (for real commute lookups) and a declared set of on-site
//  facilities, which is what lets Jeeves reason like a human planner —
//  "you're leaving straight from the gym, so take the shower there" only
//  works if the gym knows it has a shower.
//

import Foundation
import SwiftData

enum LocationKind: String, Codable, CaseIterable, Identifiable {
    case home = "Home"
    case work = "Work"
    case gym = "Gym"

    var id: String { rawValue }

    /// Sensible starting facilities per PRD §5.4 examples; the user can edit.
    var defaultFacilities: [String] {
        switch self {
        case .home: return ["reading", "job applications", "interview prep", "lunch", "chores", "photography"]
        case .gym: return ["weightlifting", "cardio", "mobility", "shower"]
        case .work: return []
        }
    }
}

@Model
final class SavedLocation {
    var kindRaw: String
    var address: String
    var facilities: [String]

    var kind: LocationKind {
        get { LocationKind(rawValue: kindRaw) ?? .home }
        set { kindRaw = newValue.rawValue }
    }

    init(kind: LocationKind, address: String = "", facilities: [String]? = nil) {
        self.kindRaw = kind.rawValue
        self.address = address
        self.facilities = facilities ?? kind.defaultFacilities
    }
}
