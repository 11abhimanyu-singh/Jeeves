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
    /// Interview prep — Reading: product reading FOR the interview. A distinct
    /// activity from the reading habit, with its own log and its own block.
    var prepReadingLogged: Bool { prepCategoriesLogged.contains(.reading) }
    /// The four question categories. Reading is NOT practice — an hour of
    /// reading about product should never tick off the block where you were
    /// meant to answer questions.
    var practiceLogged: Bool { prepCategoriesLogged.contains { $0 != .reading } }
    var appliedToJobs: Bool = false
    var readToday: Bool = false
    var leisureLogged: Set<DiscretionaryActivity> = []
}

enum AdherenceEngine {

    /// Infer an outcome for every block in the plan from the day's evidence.
    /// `cutoffMinute` (minutes since midnight) makes assessment time-aware for
    /// the CURRENT day: a block that hasn't finished by the cutoff hasn't been
    /// done OR skipped — it simply hasn't happened, so it's `.unknown`, never a
    /// premature "skipped". Pass nil for a past day (everything has elapsed).
    static func infer(plan: GeneratedPlan, evidence: DayEvidence, cutoffMinute: Int? = nil) -> [BlockOutcome] {
        plan.blocks.map { outcome(for: $0, evidence: evidence, cutoffMinute: cutoffMinute) }
    }

    private static func outcome(for block: GeneratedBlock, evidence: DayEvidence, cutoffMinute: Int?) -> BlockOutcome {
        // Not yet elapsed → not judgeable. (Keyed on the END time: an activity
        // still in progress hasn't been skipped.) Sleep wraps past midnight, but
        // it's `.unknown` regardless, so the end-time compare is harmless there.
        if let cutoff = cutoffMinute, let end = block.endMinute, end > cutoff {
            return .unknown
        }
        let t = block.title.lowercased()
        let kind = block.kind.lowercased()

        // Interview prep — Reading FIRST, because it also contains "reading"
        // and used to fall into the habit branch below. These are two
        // different activities: one is product reading for the interview,
        // logged as a PrepSession in the .reading category; the other is the
        // reading habit against the library. Judging the 90-minute must-do
        // morning block by whether a library book was opened marked it skipped
        // 19 times out of 19.
        if t.contains("interview prep"), t.contains("reading") {
            return evidence.prepReadingLogged ? .done : .skipped
        }
        // The reading habit.
        if t.contains("reading") {
            return evidence.readToday ? .done : .skipped
        }
        // Gym sub-blocks — a workout check-in confirms the whole gym visit.
        if kind == "gym" {
            return evidence.workedOut ? .done : .skipped
        }
        // Interview practice — the four question categories only. This used to
        // read `anyPrepLogged`, so an hour of prep READING ticked off the block
        // where questions were meant to be answered. The same conflation,
        // pointing the other way.
        if t.contains("interview prep") || t.contains("practice") {
            return evidence.practiceLogged ? .done : .skipped
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

    // MARK: Adherence history → adaptive planning signal

    /// How reliably one activity gets done when it's scheduled, tallied across
    /// recent days. Only assessable appearances count (a `.done`/`.skipped`
    /// outcome — `.unknown` days the activity wasn't observed are ignored).
    struct ActivityAdherence: Equatable {
        let name: String
        var done: Int
        var skipped: Int
        var scheduled: Int { done + skipped }
        var skipRate: Double { scheduled == 0 ? 0 : Double(skipped) / Double(scheduled) }
    }

    /// Group a normalizing title so the same activity tallies across days and
    /// isn't fragmented by trailing detail (gym sub-blocks stay separate; that's
    /// fine — they move together anyway).
    static func historyName(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Aggregate recent days' effective outcomes into a per-activity record of
    /// what actually gets done. `days` is (plan, effective-outcomes) pairs;
    /// only `.done`/`.skipped` blocks are counted. Sorted worst-adherence first.
    static func history(_ days: [(plan: GeneratedPlan, outcomes: [BlockOutcome])]) -> [ActivityAdherence] {
        var tally: [String: (title: String, done: Int, skipped: Int)] = [:]
        for day in days {
            for (block, outcome) in zip(day.plan.blocks, day.outcomes) {
                guard outcome == .done || outcome == .skipped else { continue }
                // Only MOVABLE routine work adapts to a skip. Anchors and fixed
                // blocks (gym sub-blocks, events, sleep, lunch, commute, the
                // wind-down) are kept regardless of adherence, so never tally
                // them — otherwise a missed gym would wrongly tell the planner
                // to "move or shorten" the gym.
                guard block.kind.lowercased() == "activity" else { continue }
                let key = historyName(block.title)
                var t = tally[key] ?? (block.title.trimmingCharacters(in: .whitespaces), 0, 0)
                if outcome == .done { t.done += 1 } else { t.skipped += 1 }
                tally[key] = t
            }
        }
        return tally.values
            .map { ActivityAdherence(name: $0.title, done: $0.done, skipped: $0.skipped) }
            .sorted { ($0.skipRate, $0.scheduled) > ($1.skipRate, $1.scheduled) }
    }

    /// A planner-facing note naming the activities the user tends NOT to do when
    /// scheduled, so the model can adapt (move, shrink, or drop them) instead of
    /// re-scheduling the same thing that never sticks. Nil when there isn't
    /// enough signal. Must-dos are never flagged (the planner keeps them) — the
    /// `routine` decides an activity's tier, so a user who marks something
    /// Must-do won't see it suggested for de-prioritizing.
    static func adherenceNote(_ history: [ActivityAdherence], routine: [BaselineActivity],
                              minSamples: Int = 2, skipThreshold: Double = 0.5) -> String? {
        let flagged = history.filter {
            $0.scheduled >= minSamples
                && $0.skipRate >= skipThreshold
                && tierByName($0.name, routine: routine) != .mustDo
        }
        guard !flagged.isEmpty else { return nil }
        let list = flagged
            .map { "\($0.name) (skipped \($0.skipped) of \($0.scheduled) times scheduled)" }
            .joined(separator: "; ")
        return "ADHERENCE HISTORY — the user tends NOT to do these when scheduled: \(list). "
            + "Adapt to what actually sticks: try a different time of day, a shorter block, or a lower priority — don't just re-schedule it the same way. Must-do items (like lunch) still stay."
    }

    /// The routine tier for an activity name (nil if it matches no routine
    /// item). Same name-matching as `tier(for:)`, but keyed by the aggregated
    /// history name rather than a live block.
    private static func tierByName(_ name: String, routine: [BaselineActivity]) -> PriorityTier? {
        let n = name.lowercased()
        return routine.first { n == $0.name.lowercased() || n.contains($0.name.lowercased()) }?.tier
    }
}
