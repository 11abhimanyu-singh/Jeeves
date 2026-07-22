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

    // MARK: Manual overrides

    /// Stable per-block key for storing a manual done/skipped mark.
    static func key(_ block: GeneratedBlock) -> String { "\(block.startTime)|\(block.title)" }

    /// The user's manual mark wins over the inferred outcome, block by block.
    static func effective(plan: GeneratedPlan, inferred: [BlockOutcome], manual: [String: BlockOutcome]) -> [BlockOutcome] {
        zip(plan.blocks, inferred).map { block, auto in manual[key(block)] ?? auto }
    }

    // MARK: Tier-weighted score

    /// Like `score`, but a missed Must-do hurts more than a missed Flexible.
    /// Weights: Must-do 3, Important 2, Flexible 1 (unmatched blocks 2). Nil
    /// when nothing is assessable.
    static func weightedScore(plan: GeneratedPlan, outcomes: [BlockOutcome], routine: [BaselineActivity]) -> Double? {
        var earned = 0.0, possible = 0.0
        for (block, outcome) in zip(plan.blocks, outcomes) where outcome != .unknown {
            let w = weight(for: block, routine: routine)
            possible += w
            if outcome == .done { earned += w }
        }
        return possible == 0 ? nil : earned / possible
    }

    private static func weight(for block: GeneratedBlock, routine: [BaselineActivity]) -> Double {
        switch tier(for: block, routine: routine) {
        case .mustDo: return 3
        case .important: return 2
        case .flexible: return 1
        case nil: return 2   // gym/unclassified: treat as Important
        }
    }

    private static func tier(for block: GeneratedBlock, routine: [BaselineActivity]) -> PriorityTier? {
        if block.kind.lowercased() == "gym" { return .important }
        let t = block.title.lowercased()
        if let match = routine.first(where: { t == $0.name.lowercased() || t.contains($0.name.lowercased()) }) {
            return match.tier
        }
        return nil
    }
}
