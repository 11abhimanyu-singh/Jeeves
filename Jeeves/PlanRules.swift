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
    /// A breather between back-to-back interview-prep blocks — time to stop
    /// thinking about one thing and start on the next.
    static let prepBreatherMinutes = 10

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

    /// Pairs of consecutive prep blocks with less than the breather between
    /// them. Empty means the plan is fine. Reported rather than repaired: the
    /// planner owns the schedule, this only refuses to let it ship unnoticed.
    static func prepBreatherViolations(_ blocks: [GeneratedBlock]) -> [String] {
        let prep = blocks
            .compactMap { b -> (title: String, start: Int, end: Int)? in
                guard isPrepBlock(title: b.title),
                      let s = b.startMinute, let e = b.endMinute else { return nil }
                return (b.title, s, e)
            }
            .sorted { $0.start < $1.start }
        guard prep.count > 1 else { return [] }

        var out: [String] = []
        for (a, b) in zip(prep, prep.dropFirst()) {
            let gap = b.start - a.end
            // A negative gap is an overlap, which the overlap check already
            // owns — don't report the same fault twice.
            guard gap >= 0, gap < prepBreatherMinutes else { continue }
            out.append("'\(a.title)' and '\(b.title)' have \(gap) min between them; "
                       + "interview-prep blocks need \(prepBreatherMinutes)")
        }
        return out
    }
}
