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

    /// Human-facing label used on chips and badges.
    var label: String {
        switch self {
        case .once:     return "Once"
        case .daily:    return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly:   return "Weekly"
        }
    }
}

@Model
final class Reminder {
    var id: UUID = UUID()
    var title: String = ""
    var fireAt: Date = Date.distantPast
    var recurrenceRaw: String = ReminderRecurrence.once.rawValue
    var enabled: Bool = true
    var completedAt: Date? = nil          // set when the user checks it off

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
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.fireAt = fireAt
        self.recurrenceRaw = recurrence.rawValue
        self.enabled = enabled
        self.completedAt = completedAt
    }
}
