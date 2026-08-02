//
//  PlanValidation.swift
//  Jeeves
//
//  Structural checks on a generated plan against the scheduler's rules — no
//  model, no key, no cost, deterministic. Used in three places from one set of
//  invariants: a runtime guardrail (PlanCoordinator retries a plan that fails a
//  SEVERE check), the eval scorer, and the fast unit suite. Catches the real
//  failures we've hit: a dropped Must-do, a midday event that discards the
//  afternoon, overlaps, out-of-bounds work.
//

import Foundation

enum PlanValidation {
    enum Severity { case severe, quality }

    struct Violation {
        let severity: Severity
        let message: String
    }

    static var dayStart: Int { DayPreferences.dayStartMinute }
    static let boundary = 20 * 60 + 30

    /// Returns every rule violation in the plan. Empty == valid.
    ///
    /// `replanNowMinute` (set on a mid-day re-plan) relaxes only what genuinely
    /// no longer holds for a partial day: the lunch window/presence once its
    /// window has passed, and the midday-event-wastes-afternoon rule. The
    /// structural invariants (non-overlap, work bounds, gym, events-present, and
    /// lunch-still-present while its window is reachable) stay enforced. Nil =
    /// the normal full-day path, byte-for-byte unchanged.
    static func validate(_ plan: GeneratedPlan, request: PlanRequest, replanNowMinute: Int? = nil) -> [Violation] {
        var out: [Violation] = []
        // Lunch is still relevant unless we're re-planning after its hard-latest
        // start (14:30) — past that a re-planned lunch legitimately can't fit.
        let lunchRelevant = replanNowMinute.map { $0 < 14 * 60 + 30 } ?? true

        let timed: [(block: GeneratedBlock, start: Int, end: Int)] = plan.blocks.compactMap {
            guard let s = $0.startMinute, let e = $0.endMinute else { return nil }
            return ($0, s, e)
        }

        // 1. Chronological & non-overlapping.
        for (a, b) in zip(timed, timed.dropFirst()) where b.start < a.end {
            out.append(Violation(severity: .severe,
                message: "\"\(b.block.title)\" (\(b.block.startTime)) overlaps \"\(a.block.title)\" (ends \(a.block.endTime))"))
        }

        // 2. Productive WORK stays inside 08:00–20:30. Events, the gym routine,
        //    and commutes are fixed commitments that follow their real times
        //    and may run later (a 19:00 gym legitimately ends past 20:30); the
        //    evening wind-down (free) and Sleep at 23:00 also live after the
        //    boundary — so the check applies only to work kinds.
        let productive: Set<String> = ["activity", "lunch"]
        // A short (≤30 min) shower block is a hygiene routine that legitimately
        // follows a late gym home — the duration cap keeps the exemption from
        // becoming an escape hatch (an "activity" titled "Shower + emails"
        // 20:30–22:30 is still work past the boundary).
        func isShowerRoutine(_ t: (block: GeneratedBlock, start: Int, end: Int)) -> Bool {
            t.block.title.localizedCaseInsensitiveContains("shower") && t.end - t.start <= 30
        }
        for t in timed where productive.contains(t.block.kind.lowercased()) && !isShowerRoutine(t) {
            if t.start < dayStart {
                out.append(Violation(severity: .severe, message: "\"\(t.block.title)\" starts before 08:00"))
            }
            if t.end > boundary {
                out.append(Violation(severity: .severe, message: "\"\(t.block.title)\" runs past 20:30"))
            }
        }

        // 2b. Gym sub-block durations are pinned — the workout must never be
        //     compressed to fit the day: Weightlifting is exactly 70 min and
        //     starts at the user's entered time; Mobility 20 and Cardio 35 are
        //     flagged as quality drift. Matching prefers kind "gym" so an event
        //     or errand with "lift"/"weight" in its title can't satisfy (or
        //     falsely trip) the check. Skipped for an unrealistically late gym
        //     (after 21:00) where the full routine can't precede 23:00 sleep —
        //     enforcing 70 min there would make the rule set unsatisfiable.
        func isWeightlifting(_ t: (block: GeneratedBlock, start: Int, end: Int)) -> Bool {
            t.block.title.localizedCaseInsensitiveContains("weight") || t.block.title.localizedCaseInsensitiveContains("lift")
        }
        if request.hasGymToday, let gymMinute = request.gymMinute, gymMinute <= 21 * 60 {
            let gymKind = timed.filter { $0.block.kind.lowercased() == "gym" }
            let lifting = gymKind.first(where: isWeightlifting)
                ?? timed.first { isWeightlifting($0) && !["event", "commute", "free", "sleep"].contains($0.block.kind.lowercased()) }
            if let lifting {
                let duration = lifting.end - lifting.start
                if duration < 70 {
                    out.append(Violation(severity: .severe, message: "Weightlifting is \(duration) min — it is a fixed 70-min block and must never be compressed"))
                }
            } else {
                out.append(Violation(severity: .severe, message: "Gym day but no weightlifting block in the plan"))
            }
            for (title, expected) in [("Mobility", 20), ("Cardio", 35)] {
                if let b = gymKind.first(where: { $0.block.title.localizedCaseInsensitiveContains(title) }) ?? timed.first(where: { $0.block.title.localizedCaseInsensitiveContains(title) && $0.block.kind.lowercased() != "event" }),
                   b.end - b.start != expected {
                    out.append(Violation(severity: .quality, message: "\(title) is \(b.end - b.start) min — expected \(expected)"))
                }
            }
        }

        // 2c. The gym visit is ONE contiguous sequence — mobility, weight-
        //     lifting, cardio back-to-back. Long activities may split around
        //     anchors; the gym never does, so any time gap (or work wedged)
        //     between gym-kind blocks is a severe violation.
        if request.hasGymToday, request.gymMinute != nil {
            let gymBlocks = timed.filter { $0.block.kind.lowercased() == "gym" }
            // Only a genuine GAP is a "split"; overlaps are already reported by
            // rule 1, and `!=` would double-report them with a contradictory
            // message (and inflate the repair loop's violation count).
            for (a, b) in zip(gymBlocks, gymBlocks.dropFirst()) where b.start > a.end {
                out.append(Violation(severity: .severe,
                    message: "Gym routine is split: \"\(b.block.title)\" starts at \(hhmm(b.start)) but \"\(a.block.title)\" ends at \(hhmm(a.end)) — mobility, weightlifting, cardio must run back-to-back"))
            }
        }

        // 2d. A commute must deliver you to something. A plan that reads
        //     "Commute Home → Gym · 18-min trip to arrive for mobility" and
        //     then schedules interview prep — with no gym block anywhere —
        //     satisfied every other rule here and still shipped, because
        //     nothing checked that a journey's destination matched what came
        //     next. Gym-bound commutes are the checkable case: the title names
        //     the destination, so the block after it must be the gym.
        let gymBound = timed.filter {
            $0.block.kind.lowercased() == "commute"
                && $0.block.title.localizedCaseInsensitiveContains("gym")
                && !$0.block.title.localizedCaseInsensitiveContains("Gym →")
                && !$0.block.title.localizedCaseInsensitiveContains("Gym—")
        }
        for leg in gymBound {
            // Outbound only: "Gym → Home" legitimately precedes anything.
            guard leg.block.title.localizedCaseInsensitiveContains("→ Gym")
                    || leg.block.title.localizedCaseInsensitiveContains("to Gym") else { continue }
            let next = timed.first { $0.start >= leg.end }
            if next?.block.kind.lowercased() != "gym" {
                out.append(Violation(severity: .severe,
                    message: "\"\(leg.block.title)\" (\(leg.block.startTime)–\(leg.block.endTime)) is a journey to the gym, but the next block is \(next.map { "\"\($0.block.title)\"" } ?? "nothing") — a commute must arrive somewhere the day actually goes"))
            }
        }

        // 3. A Must-do (lunch) must never be dropped, and lunch must appear.
        //    (Interview-prep reading is now a high-preference Important item —
        //    it MAY be dropped when the day is too full, so it's not checked
        //    here.)
        for d in plan.dropped {
            let dl = d.lowercased()
            if dl.contains("must-do") || dl.contains("lunch") {
                out.append(Violation(severity: .severe, message: "Must-do dropped: \(d)"))
            }
        }
        if let lunch = timed.first(where: { $0.block.kind.lowercased() == "lunch" || $0.block.title.localizedCaseInsensitiveContains("lunch") }) {
            // Window: 12:30 earliest, finish by 14:00 preferred, 14:30 hard latest
            // start. On a re-plan past the window, a preserved/late lunch is fine.
            if lunchRelevant {
                if lunch.start < 12 * 60 + 30 {
                    out.append(Violation(severity: .severe, message: "Lunch starts at \(hhmm(lunch.start)) — before the 12:30 earliest (no late-morning brunch)"))
                }
                if lunch.start > 14 * 60 + 30 {
                    out.append(Violation(severity: .severe, message: "Lunch starts at \(hhmm(lunch.start)) — past the 14:30 Must-do deadline"))
                } else if lunch.end > 14 * 60 {
                    out.append(Violation(severity: .quality, message: "Lunch finishes at \(hhmm(lunch.end)) — past the 14:00 finish preference"))
                }
            }
        } else if lunchRelevant {
            // Once the lunch window has passed on a re-plan, a missing lunch is
            // legitimate (it was skipped); before then it must still appear.
            out.append(Violation(severity: .severe, message: "Lunch (a Must-do) is missing from the plan"))
        }

        // 4. Every TIMED event is an anchor and must appear — none may be dropped.
        //    All-day events have no block (they're day-long context), so they're
        //    excluded from the count.
        let eventBlocks = plan.blocks.filter { $0.kind.lowercased() == "event" }.count
        let timedEventCount = request.events.filter { !$0.isAllDay }.count
        if eventBlocks < timedEventCount {
            out.append(Violation(severity: .severe,
                message: "Plan has \(eventBlocks) event block(s) but \(timedEventCount) were given — an event was dropped"))
        }

        // 5. A midday event must not discard the rest of the day: if the last
        //    event ends with hours to spare and work was dropped, there must be
        //    productive work after it. (The exact bug we fixed.) A mid-day
        //    re-plan is already a partial day, so this doesn't apply there.
        if replanNowMinute == nil,
           let lastEventEnd = timed.filter({ $0.block.kind.lowercased() == "event" }).map(\.end).max(),
           lastEventEnd <= 17 * 60, !plan.dropped.isEmpty {
            let workAfter = timed.contains { $0.start >= lastEventEnd && ["activity", "lunch"].contains($0.block.kind.lowercased()) }
            if !workAfter {
                out.append(Violation(severity: .severe,
                    message: "Event ends by \(hhmm(lastEventEnd)) and work was dropped, but nothing productive is scheduled after it — the afternoon/evening is wasted"))
            }
        }

        // Two prep blocks butted together. A rule that lives only in the prompt
        // is a request — the gym durations were "FIXED" for months with nothing
        // checking whether the model agreed.
        for message in PlanRules.prepBreatherViolations(plan.blocks) {
            out.append(Violation(severity: .quality, message: message))
        }

        // A shaved commute is severe, not cosmetic: it is the one kind of error
        // that makes the user physically late. Travel time and parking are
        // facts; when the day is too full an ACTIVITY gives way, never these.
        for entry in timed {
            guard let match = CommuteBuffer.matchRoute(blockTitle: entry.block.title,
                                                       in: request.commuteEstimates) else { continue }
            let floor = CommuteBuffer.minimumMinutes(route: match.route, measured: match.minutes)
            let actual = entry.end - entry.start
            if actual < floor {
                let parking = CommuteBuffer.needsParking(route: match.route)
                out.append(Violation(severity: .severe,
                    message: "'\(entry.block.title)' is \(actual) min but \(match.route) measures \(match.minutes) min"
                        + (parking ? " + \(CommuteBuffer.parkingMinutes) min parking" : "")
                        + " = \(floor). Commute and parking are never trimmed to fit something else."))
            }
        }

        return out
    }

    static func severe(_ plan: GeneratedPlan, request: PlanRequest, replanNowMinute: Int? = nil) -> [Violation] {
        validate(plan, request: request, replanNowMinute: replanNowMinute).filter { $0.severity == .severe }
    }

    private static func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
}
