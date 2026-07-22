//
//  AdherenceEngine.swift
//  Jeeves
//
//  Answers "did the plan actually get followed?" — the signal that tells us
//  whether the planner is meaningful. The key idea: don't add a logging chore.
//  Jeeves already records ground truth independent of the plan (check-ins, prep
//  sessions, job applications, reading and leisure logs), so we cross-reference
//  each plan block against those logs and INFER whether it happened. Pure and
//  unit-tested; the UI just displays the result.
//

import Foundation

enum BlockOutcome: String, Codable {
    case done       // a log confirms this happened
    case skipped    // this block is assessable, but no log confirms it
    case unknown    // nothing independently records this block (lunch, commute, sleep…)
}

/// The day's ground-truth logs, reduced to the booleans inference needs.
struct DayEvidence {
    var workedOut: Bool = false
    var prepCategoriesLogged: Set<PrepCategory> = []
    var anyPrepLogged: Bool { !prepCategoriesLogged.isEmpty }
    var appliedToJobs: Bool = false
    var readToday: Bool = false
    var leisureLogged: Set<DiscretionaryActivity> = []
}

enum AdherenceEngine {

    /// Infer an outcome for every block in the plan from the day's evidence.
    static func infer(plan: GeneratedPlan, evidence: DayEvidence) -> [BlockOutcome] {
        plan.blocks.map { outcome(for: $0, evidence: evidence) }
    }

    private static func outcome(for block: GeneratedBlock, evidence: DayEvidence) -> BlockOutcome {
        let t = block.title.lowercased()
        let kind = block.kind.lowercased()

        // Reading (peak-focus interview reading OR the reading habit).
        if t.contains("reading") {
            return evidence.readToday ? .done : .skipped
        }
        // Gym sub-blocks — a workout check-in confirms the whole gym visit.
        if kind == "gym" {
            return evidence.workedOut ? .done : .skipped
        }
        // Interview practice.
        if t.contains("interview prep") || t.contains("practice") {
            return evidence.anyPrepLogged ? .done : .skipped
        }
        // Job applications.
        if t.contains("job application") {
            return evidence.appliedToJobs ? .done : .skipped
        }
        // Photography / discretionary leisure.
        if t.contains("photography") {
            return evidence.leisureLogged.contains(.photography) ? .done : .skipped
        }
        // Everything else (lunch, commute, gym commute, showers, chores, free,
        // sleep, events) isn't independently logged → we can't assess it.
        return .unknown
    }

    /// A 0–1 completion score over the blocks we can actually assess (unknowns
    /// excluded so they don't dilute the result). Nil when nothing is
    /// assessable yet — an unlogged day isn't a zero-adherence day.
    static func score(_ outcomes: [BlockOutcome]) -> Double? {
        let assessable = outcomes.filter { $0 != .unknown }
        guard !assessable.isEmpty else { return nil }
        let done = assessable.filter { $0 == .done }.count
        return Double(done) / Double(assessable.count)
    }

    /// Count of assessable blocks — how much of the day we could actually judge.
    static func assessableCount(_ outcomes: [BlockOutcome]) -> Int {
        outcomes.filter { $0 != .unknown }.count
    }
}
