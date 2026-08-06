//
//  Reminder.swift
//  Jeeves
//
//  A single timed nudge the user sets for themselves — "Take meds at 9:00",
//  "Call the dentist Friday". Reminders fire as local notifications, so the
//  actual scheduling lives in ReminderScheduler; this is just the stored shape.
//  All properties carry defaults and enums are stored as raw strings so the
//  model is CloudKit-ready.
//

import Foundation
import SwiftData

/// How often a reminder repeats after its first fire.
enum ReminderRecurrence: String, CaseIterable {
    case once
    case daily
    case weekdays   // Monday–Friday
    case weekly     // same weekday each week
    /// Every N days from the anchor date, N held in `Reminder.intervalDays`.
    ///
    /// The odd one out: every other case is a DateComponents match the OS can
    /// repeat forever, but no components describe "every third day" — a period
    /// that isn't a week doesn't align to any calendar field. So this one is
    /// scheduled as a rolling window of concrete dates and topped up on launch.
    case everyNDays

    /// Human-facing label used on chips and badges.
    var label: String {
        switch self {
        case .once:      return "Once"
        case .daily:     return "Daily"
        case .weekdays:  return "Weekdays"
        case .weekly:    return "Weekly"
        case .everyNDays: return "Every…"
        }
    }

    /// Does this recurrence need an interval to mean anything?
    var needsInterval: Bool { self == .everyNDays }
}

@Model
final class Reminder {
    var id: UUID = UUID()
    var title: String = ""
    var fireAt: Date = Date.distantPast
    var recurrenceRaw: String = ReminderRecurrence.once.rawValue
    var enabled: Bool = true
    var completedAt: Date? = nil          // set when the user checks it off
    /// For `.everyNDays` only: how many days apart. Defaulted for CloudKit, and
    /// meaningless (ignored) for every other recurrence.
    var intervalDays: Int = 2

    /// Typed accessor over the raw string the store keeps.
    var recurrence: ReminderRecurrence {
        get { ReminderRecurrence(rawValue: recurrenceRaw) ?? .once }
        set { recurrenceRaw = newValue.rawValue }
    }

    /// A reminder that should currently hold a scheduled notification.
    var isActive: Bool { enabled && completedAt == nil }

    init(
        id: UUID = UUID(),
        title: String = "",
        fireAt: Date = Date.distantPast,
        recurrence: ReminderRecurrence = .once,
        enabled: Bool = true,
        completedAt: Date? = nil,
        intervalDays: Int = 2
    ) {
        self.id = id
        self.title = title
        self.fireAt = fireAt
        self.recurrenceRaw = recurrence.rawValue
        self.enabled = enabled
        self.completedAt = completedAt
        self.intervalDays = max(1, intervalDays)
    }
}

extension ReminderRecurrence {
    /// The next `count` times a reminder fires, from `anchor`, at or after
    /// `now`. Pure, so the arithmetic is tested rather than trusted, and shared
    /// by the scheduler and the "next three dates" preview — a preview that
    /// disagreed with what actually fires would be worse than no preview.
    ///
    /// Only `.everyNDays` needs this: every other case is a DateComponents
    /// match the OS repeats on its own.
    func occurrences(anchor: Date, intervalDays: Int, count: Int,
                     now: Date = Date(), cal: Calendar = .current) -> [Date] {
        guard self == .everyNDays, count > 0 else { return [] }
        let step = max(1, intervalDays)
        var date = anchor
        // Walk forward from the anchor rather than from now, so the rhythm stays
        // pinned to the day the user chose — "every 3 days from Monday" must not
        // silently re-phase because the app happened to reschedule on Tuesday.
        if date <= now {
            let days = cal.dateComponents([.day], from: date, to: now).day ?? 0
            let skip = (days / step + 1) * step
            date = cal.date(byAdding: .day, value: skip, to: date) ?? date
            // Overshoot by at most one period if the anchor time is still ahead.
            if let back = cal.date(byAdding: .day, value: -step, to: date), back > now { date = back }
        }
        var out: [Date] = []
        while out.count < count {
            out.append(date)
            guard let next = cal.date(byAdding: .day, value: step, to: date) else { break }
            date = next
        }
        return out
    }
}
