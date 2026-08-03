//
//  AdherenceStats.swift
//  Jeeves
//
//  The numbers behind the adherence screen, kept pure so they're tested
//  rather than trusted.
//
//  One rule governs all of it: NEVER SHOW A RATE THAT HIDES ITS DENOMINATOR.
//  Blocks the app never asked about are excluded from the percentage and
//  reported separately. Fold them in as misses and a week where the chain
//  stalled reads as a week you slacked — which then feeds the planner and
//  shrinks the very blocks you did do.
//

import Foundation

struct AdherenceStats {

    struct DayRoll: Identifiable {
        var id: Date { day }
        var day: Date
        var done: Int = 0
        var skipped: Int = 0
        var unknown: Int = 0
        var isTravel: Bool = false
        var assessable: Int { done + skipped }
    }

    /// How long an activity actually takes versus what the plan allows. The
    /// reason the timing data is worth collecting at all: without a loop like
    /// this, actual-vs-planned is bookkeeping with a daily compliance cost.
    struct Drift: Identifiable {
        var id: String { title }
        var title: String
        var plannedMinutes: Int
        var medianActualMinutes: Int
        var sessions: Int
        var driftMinutes: Int { medianActualMinutes - plannedMinutes }
        /// Enough runs to be a pattern rather than a bad afternoon.
        var isConfident: Bool { sessions >= 3 }
    }

    struct Gap: Identifiable {
        var id: String { reason }
        var reason: String
        var count: Int
    }

    var days: [DayRoll] = []
    var drifts: [Drift] = []
    var totals: [(unit: ActivityUnit, count: Int)] = []
    var gaps: [Gap] = []

    var done: Int { days.reduce(0) { $0 + $1.done } }
    var skipped: Int { days.reduce(0) { $0 + $1.skipped } }
    var unknown: Int { days.reduce(0) { $0 + $1.unknown } }
    var assessable: Int { done + skipped }

    /// Nil when nothing was assessable — a percentage over zero blocks is not
    /// 0%, it is no answer, and printing 0% would read as total failure.
    var rate: Double? {
        guard assessable > 0 else { return nil }
        return Double(done) / Double(assessable)
    }

    // MARK: building

    /// `outcomes` is the effective per-block verdict for each day, already
    /// resolved (manual marks beating inference), so this only counts.
    static func build(days: [(day: Date, outcomes: [BlockOutcome], isTravel: Bool)],
                      sessions: [ActivitySession],
                      routine: [RoutineActivity]) -> AdherenceStats {
        var stats = AdherenceStats()

        stats.days = days.map { entry in
            var roll = DayRoll(day: entry.day.startOfDay, isTravel: entry.isTravel)
            for outcome in entry.outcomes {
                switch outcome {
                case .done:    roll.done += 1
                case .skipped: roll.skipped += 1
                case .unknown: roll.unknown += 1
                }
            }
            return roll
        }

        // Drift, from sessions with a trustworthy duration. `needsDetail` is
        // excluded on purpose: an auto-closed session knows when it started
        // and nothing else, and averaging it in would teach the planner a
        // number nobody measured.
        let usable = sessions.filter { $0.state == .done && $0.plannedMinutes > 0 }
        let byTitle = Dictionary(grouping: usable, by: \.title)
        stats.drifts = byTitle.compactMap { title, group -> Drift? in
            let actuals = group.map(\.actualMinutes).sorted()
            guard let median = actuals.middle else { return nil }
            let planned = routine.first { title.localizedCaseInsensitiveContains($0.name) }?.durationMinutes
                ?? group[0].plannedMinutes
            return Drift(title: title, plannedMinutes: planned,
                         medianActualMinutes: median, sessions: group.count)
        }
        .sorted { abs($0.driftMinutes) > abs($1.driftMinutes) }

        // What you got through.
        var counts: [ActivityUnit: Int] = [:]
        for session in sessions where session.quantityGiven {
            guard let unit = session.unit else { continue }
            counts[unit, default: 0] += session.quantity
        }
        stats.totals = ActivityUnit.allCases.compactMap { unit in
            counts[unit].map { (unit, $0) }
        }

        // What Jeeves doesn't know — the panel most stats screens omit.
        var gaps: [Gap] = []
        let neverAsked = stats.unknown
        if neverAsked > 0 { gaps.append(Gap(reason: "never asked", count: neverAsked)) }
        let unclosed = sessions.filter { $0.state == .needsDetail }.count
        if unclosed > 0 { gaps.append(Gap(reason: "closed itself, duration unknown", count: unclosed)) }
        let uncounted = sessions.filter { $0.state == .done && $0.unit != nil && !$0.quantityGiven }.count
        if uncounted > 0 { gaps.append(Gap(reason: "logged, no count given", count: uncounted)) }
        stats.gaps = gaps

        return stats
    }
}

private extension Array where Element == Int {
    /// The middle value of a sorted array; for an even count, the lower of the
    /// two middles. Median rather than mean because one four-hour afternoon
    /// shouldn't rewrite a 45-minute routine.
    var middle: Int? { isEmpty ? nil : self[count / 2] }
}
