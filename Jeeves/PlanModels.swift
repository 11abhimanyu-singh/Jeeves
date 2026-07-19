//
//  PlanModels.swift
//  Jeeves
//
//  Shared types for Claude-generated day plans (PRD §5.1, §6): the user's
//  baseline routine with priority tiers, and the strict response contract
//  the plan-generation call must return so the app can parse it by
//  content/type — never by array position (PRD §6).
//

import Foundation

// MARK: - Baseline routine (PRD §5.1)

enum PriorityTier: String, Codable {
    case mustDo = "Must-do"      // never dropped; shrink only as last resort
    case important = "Important"
    case flexible = "Flexible"   // dropped first
}

struct BaselineActivity {
    let name: String
    let durationMinutes: Int
    let tier: PriorityTier
    let note: String?
}

enum Baseline {
    /// The user's fixed daily routine. Anchors (gym, events) sit above all of
    /// these and are supplied per-day, not here.
    static let activities: [BaselineActivity] = [
        BaselineActivity(name: "Interview prep — Reading", durationMinutes: 90, tier: .mustDo, note: "Morning peak-focus slot"),
        BaselineActivity(name: "Lunch", durationMinutes: 45, tier: .mustDo, note: nil),
        BaselineActivity(name: "Job applications", durationMinutes: 90, tier: .important, note: nil),
        BaselineActivity(name: "Interview prep — practice", durationMinutes: 120, tier: .important, note: "Split across Product Sense / Execution / Strategy / Behavioral, weighted toward the most-neglected"),
        BaselineActivity(name: "Reading habit", durationMinutes: 90, tier: .important, note: nil),
        BaselineActivity(name: "Chores", durationMinutes: 40, tier: .flexible, note: nil),
        BaselineActivity(name: "Chore buffer", durationMinutes: 30, tier: .flexible, note: nil),
        BaselineActivity(name: "Photography", durationMinutes: 30, tier: .flexible, note: nil),
    ]

    static let dayStartMinute = 8 * 60       // 8:00 AM
    static let normalBoundaryMinute = 20 * 60 + 30  // 8:30 PM
}

// MARK: - Claude response contract (PRD §6)

/// One entry in the returned schedule. `kind` classifies it so the UI can
/// render/anchor by type rather than guessing from the title.
struct GeneratedBlock: Decodable {
    let title: String
    let startTime: String       // "HH:MM", 24-hour
    let endTime: String         // "HH:MM"
    let note: String?
    let isAnchor: Bool
    let kind: String            // "activity" | "commute" | "gym" | "event" | "lunch" | "free"

    var startMinute: Int? { Self.minutes(from: startTime) }
    var endMinute: Int? { Self.minutes(from: endTime) }

    static func minutes(from hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

/// What Jeeves changed to make the day fit, surfaced to the user verbatim
/// (PRD §5.3 rule 4: never silently drop/shrink).
struct GeneratedPlan: Decodable {
    let blocks: [GeneratedBlock]
    let dropped: [String]           // activities left out entirely
    let shrunk: [String]            // activities kept but shortened (human-readable, e.g. "prep 120→70")
    let summary: String             // Jeeves's plain-language explanation of the day + trade-offs
    let boundaryTime: String?       // "HH:MM" hard boundary in force (departure time on event days)
}
