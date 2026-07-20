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

    static let dayStart = 8 * 60
    static let boundary = 20 * 60 + 30

    /// Returns every rule violation in the plan. Empty == valid.
    static func validate(_ plan: GeneratedPlan, request: PlanRequest) -> [Violation] {
        var out: [Violation] = []

        let timed: [(block: GeneratedBlock, start: Int, end: Int)] = plan.blocks.compactMap {
            guard let s = $0.startMinute, let e = $0.endMinute else { return nil }
            return ($0, s, e)
        }

        // 1. Chronological & non-overlapping.
        for (a, b) in zip(timed, timed.dropFirst()) where b.start < a.end {
            out.append(Violation(severity: .severe,
                message: "\"\(b.block.title)\" (\(b.block.startTime)) overlaps \"\(a.block.title)\" (ends \(a.block.endTime))"))
        }

        // 2. Non-event/commute work stays inside 08:00–20:30. Events (and the
        //    commutes to/from them) follow their real times and may run later.
        for t in timed where !["event", "commute"].contains(t.block.kind.lowercased()) {
            if t.start < dayStart {
                out.append(Violation(severity: .severe, message: "\"\(t.block.title)\" starts before 08:00"))
            }
            if t.end > boundary {
                out.append(Violation(severity: .severe, message: "\"\(t.block.title)\" runs past 20:30"))
            }
        }

        // 3. A Must-do (morning reading, lunch) must never be dropped, and lunch
        //    must appear in the plan.
        for d in plan.dropped {
            let dl = d.lowercased()
            if dl.contains("must-do") || dl.contains("lunch") || (dl.contains("interview prep") && dl.contains("reading")) {
                out.append(Violation(severity: .severe, message: "Must-do dropped: \(d)"))
            }
        }
        if let lunch = timed.first(where: { $0.block.kind.lowercased() == "lunch" || $0.block.title.localizedCaseInsensitiveContains("lunch") }) {
            if lunch.start > 14 * 60 + 30 {
                out.append(Violation(severity: .severe, message: "Lunch starts at \(hhmm(lunch.start)) — past the 14:30 Must-do deadline"))
            }
        } else {
            out.append(Violation(severity: .severe, message: "Lunch (a Must-do) is missing from the plan"))
        }

        // 4. Every event is an anchor and must appear — none may be dropped.
        let eventBlocks = plan.blocks.filter { $0.kind.lowercased() == "event" }.count
        if eventBlocks < request.events.count {
            out.append(Violation(severity: .severe,
                message: "Plan has \(eventBlocks) event block(s) but \(request.events.count) were given — an event was dropped"))
        }

        // 5. A midday event must not discard the rest of the day: if the last
        //    event ends with hours to spare and work was dropped, there must be
        //    productive work after it. (The exact bug we fixed.)
        if let lastEventEnd = timed.filter({ $0.block.kind.lowercased() == "event" }).map(\.end).max(),
           lastEventEnd <= 17 * 60, !plan.dropped.isEmpty {
            let workAfter = timed.contains { $0.start >= lastEventEnd && ["activity", "lunch"].contains($0.block.kind.lowercased()) }
            if !workAfter {
                out.append(Violation(severity: .severe,
                    message: "Event ends by \(hhmm(lastEventEnd)) and work was dropped, but nothing productive is scheduled after it — the afternoon/evening is wasted"))
            }
        }

        return out
    }

    static func severe(_ plan: GeneratedPlan, request: PlanRequest) -> [Violation] {
        validate(plan, request: request).filter { $0.severity == .severe }
    }

    private static func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
}
