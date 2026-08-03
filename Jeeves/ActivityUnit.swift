//
//  ActivityUnit.swift
//  Jeeves
//
//  What a block is measured in — and, by the same answer, whether it is
//  measured at all.
//
//  Requirement 5 says commutes, chores and free time have nothing worth
//  counting. That was already half-true in the app: AdherenceEngine decided
//  assessability by matching substrings in the title, in one place, while
//  nothing anywhere knew what a block's UNIT was. Two systems answering
//  "is this measurable?" differently is how you end up nagged for a page
//  count on your drive home.
//
//  So this is the single answer. AdherenceEngine reads it too.
//

import Foundation

enum ActivityUnit: String, Codable, CaseIterable {
    case questions, pages, articles, applications, frames

    /// Shown under the stepper.
    var label: String {
        switch self {
        case .questions:    return "questions practised"
        case .pages:        return "pages"
        case .articles:     return "articles"
        case .applications: return "applications sent"
        case .frames:       return "frames kept"
        }
    }

    /// Compact, for a chip or a stat tile.
    var short: String { rawValue }

    /// Counts that make sense inside one sitting. Deliberately small numbers:
    /// a stepper beats a keyboard at the moment you're trying to leave.
    var quickPicks: [Int] {
        switch self {
        case .questions:    return [3, 5, 8, 10]
        case .pages:        return [10, 20, 30, 50]
        case .articles:     return [1, 2, 3, 5]
        case .applications: return [1, 2, 3, 5]
        case .frames:       return [5, 10, 20, 40]
        }
    }

    /// The unit a plan block is counted in, or nil when it isn't measured.
    ///
    /// NOTE ON BOOKS: reading is counted in PAGES, never books. A book is a
    /// multi-week unit — counting them per session records mostly zeroes and
    /// teaches the planner you never read.
    static func forBlock(title: String, kind: String = "") -> ActivityUnit? {
        let t = title.lowercased()
        let k = kind.lowercased()

        // Explicitly unmeasured, whatever the title says.
        if ["commute", "lunch", "free", "sleep"].contains(k) { return nil }
        for word in ["commute", "shower", "lunch", "sleep", "wind-down", "wind down",
                     "free time", "chore", "breather", "slack", "morning routine",
                     "discretionary", "travel", "drive"] where t.contains(word) {
            return nil
        }

        // The gym is logged on the Watch, in far more detail than a count.
        if k == "gym" || t.contains("gym") { return nil }

        if t.contains("job application") { return .applications }
        if t.contains("photography") { return .frames }

        // Prep reading is product reading FOR the interview; the reading habit
        // is the library. Both are pages — they differ in which log they feed,
        // not in how they're counted.
        if t.contains("reading") { return .pages }
        if t.contains("interview prep") || t.contains("practice") { return .questions }
        if Baseline.practiceCategories.contains(where: { t.contains($0.rawValue.lowercased()) }) {
            return .questions
        }
        return nil
    }

    /// Is this block one Jeeves can assess at all? Same question, same answer.
    static func isMeasurable(title: String, kind: String = "") -> Bool {
        forBlock(title: title, kind: kind) != nil
    }
}
