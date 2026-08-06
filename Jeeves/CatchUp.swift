//
//  CatchUp.swift
//  Jeeves
//
//  The prompt that makes the one-day backfill window usable.
//
//  Without it the window exists but you have to remember to go looking — on
//  precisely the day you had already demonstrated you weren't looking at your
//  phone. Editable until the end of the next calendar day means a Friday
//  afternoon is out of reach by Monday, so the ask has to come to you.
//
//  It asks ONCE per day and only about blocks it genuinely failed to resolve:
//  ones whose nudge the chain withheld, and sessions that closed themselves
//  without a duration. A block you were asked about and skipped is not a
//  question — it is an answer, and re-asking would be nagging.
//

import Foundation
import SwiftData

enum CatchUp {

    /// One block still owed an answer.
    struct Pending: Identifiable, Equatable {
        var id: String { "\(day.timeIntervalSince1970)|\(blockKey)" }
        var day: Date
        var blockKey: String
        var title: String
        var plannedMinutes: Int
        /// Why it's here — shown so the ask explains itself.
        var reason: Reason

        enum Reason: Equatable {
            case neverAsked      // the chain held its nudge
            case closedItself    // auto-closed, duration unknown
            /// Marked skipped on a day that has now passed. Not a question —
            /// the user already answered it — but the work itself is still
            /// undone and had nowhere to go. "Collect spectacles" was
            /// scheduled and skipped on the 4th AND the 5th, and nothing ever
            /// offered to do anything about it.
            case leftUndone

            var label: String {
                switch self {
                case .neverAsked:   return "never asked"
                case .closedItself: return "closed itself"
                case .leftUndone:   return "not done"
                }
            }

            /// Whether the honest question is "did you?" or "what now?".
            var wantsRescue: Bool { self == .leftUndone }
        }
    }

    /// What the app owes an answer for, across the backfill window.
    /// Pure input, so the rules are tested rather than trusted.
    static func pending(days: [(day: Date, plan: GeneratedPlan?, withheld: Set<String>,
                                answered: Set<String>, skipped: Set<String>)],
                        sessions: [ActivitySession],
                        now: Date = .now) -> [Pending] {
        var out: [Pending] = []
        let cal = Calendar.current

        for entry in days {
            guard ActivityTracker.isWithinBackfillWindow(entry.day, now: now) else { continue }

            // Work the user SAID they didn't do, on a day that has now passed.
            // Only once the day is over: a block skipped this morning may still
            // happen this evening, and asking about it at lunchtime would be
            // the app nagging rather than helping.
            if let plan = entry.plan, entry.day.startOfDay < now.startOfDay {
                for block in plan.blocks {
                    let key = AdherenceEngine.key(block)
                    guard entry.skipped.contains(key), !entry.answered.contains(key) else { continue }
                    out.append(Pending(day: entry.day, blockKey: key, title: block.title,
                                       plannedMinutes: max(0, (block.endMinute ?? 0) - (block.startMinute ?? 0)),
                                       reason: .leftUndone))
                }
            }

            // Blocks whose nudge the chain swallowed.
            if let plan = entry.plan {
                for block in plan.blocks {
                    let key = AdherenceEngine.key(block)
                    guard entry.withheld.contains(key),
                          ActivityUnit.isMeasurable(title: block.title, kind: block.kind),
                          !entry.answered.contains(key),
                          // A block can be both withheld and later marked
                          // skipped; "what now?" outranks "did you?", because
                          // the second question already has its answer.
                          !out.contains(where: { $0.blockKey == key && $0.day == entry.day })
                    else { continue }
                    out.append(Pending(day: entry.day, blockKey: key, title: block.title,
                                       plannedMinutes: max(0, (block.endMinute ?? 0) - (block.startMinute ?? 0)),
                                       reason: .neverAsked))
                }
            }

            // Sessions that ran and closed themselves. They know when they
            // started and nothing else, so they're still an open question.
            for session in sessions where session.state == .needsDetail
                && cal.isDate(session.day, inSameDayAs: entry.day) {
                guard !out.contains(where: { $0.blockKey == session.blockKey && $0.day == entry.day })
                else { continue }
                out.append(Pending(day: entry.day, blockKey: session.blockKey,
                                   title: session.title, plannedMinutes: session.plannedMinutes,
                                   reason: .closedItself))
            }
        }
        return out.sorted { ($0.day, $0.title) < ($1.day, $1.title) }
    }

    /// Ask once a day, not every time the app opens.
    static let lastShownKey = "jeeves.catchUp.lastShown"

    static func shouldAsk(now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        let stamp = defaults.double(forKey: lastShownKey)
        guard stamp > 0 else { return true }
        return !Calendar.current.isDate(Date(timeIntervalSince1970: stamp), inSameDayAs: now)
    }

    static func markAsked(now: Date = .now, defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: lastShownKey)
    }
}

// Two-key ordering, so the list reads day-then-title rather than arbitrarily.
private func < (lhs: (Date, String), rhs: (Date, String)) -> Bool {
    lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
}
