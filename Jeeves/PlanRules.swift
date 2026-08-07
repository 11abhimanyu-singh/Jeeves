//
//  PlanRules.swift
//  Jeeves
//
//  Shape rules a generated plan has to satisfy, kept where the prompt, the
//  offline fallback and the validator can all read the same number.
//
//  The gym durations taught this lesson: three figures written into a prompt
//  sentence and repeated in DayPlanner, with nothing checking the model
//  actually honoured them. A rule stated only in a prompt is a request; a rule
//  with a checker is a rule.
//

import Foundation

enum PlanRules {
    /// How long you can work continuously before the day owes you a break.
    static let maxContinuousMinutes = 90
    /// The break itself.
    static let breakMinutes = 10

    /// Kept as the old name so the prep-specific call sites still read, but it
    /// is now the general break — see `longRunViolations`.
    static let prepBreatherMinutes = breakMinutes

    /// Does this block tire you? Only real work counts toward a run.
    ///
    /// Lunch, a commute, the gym, free time and sleep all RESET the count —
    /// they are already the break. That is the rule's whole subtlety: a plan
    /// with lunch in the middle of a long stretch needs nothing added, and
    /// inserting a breather beside lunch would read as the app not noticing
    /// the meal it just scheduled.
    static func isContinuousWork(kind: String) -> Bool {
        kind.lowercased() == "activity"
    }

    /// Runs of work longer than `maxContinuousMinutes` with no break in them.
    ///
    /// This replaces a prep-only breather that fired between two interview-prep
    /// blocks and nowhere else — so 150 minutes of prep was caught while 150
    /// minutes of anything else was not. The trigger is now the LENGTH of the
    /// run rather than what the run happens to contain.
    static func longRunViolations(_ blocks: [GeneratedBlock]) -> [String] {
        let timed = blocks
            .compactMap { b -> (title: String, kind: String, start: Int, end: Int)? in
                guard let s = b.startMinute, let e = b.endMinute, e > s else { return nil }
                return (b.title, b.kind, s, e)
            }
            .sorted { $0.start < $1.start }

        var out: [String] = []
        var runMinutes = 0
        var runStartTitle = ""
        var previousEnd: Int?

        for t in timed {
            // Anything that is not work, or a real gap, ends the run. A
            // NEGATIVE gap is an overlap, which the overlap check already owns
            // — summing two blocks that occupy the same minutes would invent a
            // long run out of a fault someone else is already reporting.
            let gap = previousEnd.map { t.start - $0 } ?? 0
            if !isContinuousWork(kind: t.kind) || gap >= breakMinutes || gap < 0 {
                runMinutes = 0
                previousEnd = t.end
                if isContinuousWork(kind: t.kind) { runMinutes = t.end - t.start; runStartTitle = t.title }
                continue
            }
            if runMinutes == 0 { runStartTitle = t.title }
            runMinutes += t.end - t.start
            if runMinutes > maxContinuousMinutes {
                out.append("'\(runStartTitle)' through '\(t.title)' is \(runMinutes) min of unbroken work; "
                           + "after \(maxContinuousMinutes) min there must be a \(breakMinutes)-minute break")
                runMinutes = 0   // report a run once, not once per block after it
            }
            previousEnd = t.end
        }
        return out
    }

    /// Is this block one of the interview-prep family? Prep reading and the
    /// four practice categories all qualify; the reading HABIT does not, which
    /// is why the test is the prep prefix and not the word "reading".
    static func isPrepBlock(title: String) -> Bool {
        let t = title.lowercased()
        if t.contains("interview prep") { return true }
        if t.contains("practice") { return true }
        // Group-prefixed children: "Interview prep — Product Sense".
        return Baseline.practiceCategories.contains { t.contains($0.rawValue.lowercased()) }
            && !t.contains("habit")
    }

}
