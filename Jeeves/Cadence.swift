//
//  Cadence.swift
//  Jeeves
//
//  Which days a routine activity actually applies to.
//
//  The routine used to carry a duration and a tier and nothing else, so all
//  twelve enabled activities were candidates every single day — 8h 45m of work
//  against a 12h 30m window, before commutes and before events. It could not
//  fit, so the planner shrank and fragmented until the arithmetic closed and
//  then tried the identical thing tomorrow. "Not daily" had no way to be said,
//  and the on/off switch was doing that job badly: Photography was switched off
//  and a second Reading row silenced, when neither was meant to be never.
//
//  Pure by construction — the day is always passed in, never read from the
//  clock inside. RemindersListView.firesToday is the counter-example: it reads
//  Date() inline and is therefore untested.
//

import Foundation

/// The set of weekdays an activity runs on.
///
/// Weekday numbers follow Foundation's `Calendar.component(.weekday,…)`:
/// **Sunday = 1 … Saturday = 7**, so Monday–Friday is `2...6`. That is the same
/// convention `ReminderScheduler` already fans out over, and matching it means
/// the two schedules can be compared without a translation layer.
struct Cadence: Equatable {

    /// Empty means EVERY day. That is what makes this change safe to ship: a
    /// stored row with no cadence behaves exactly as it did before, so there is
    /// no backfill to run and no migration that can half-apply.
    let weekdays: Set<Int>

    static let everyDay = Cadence(weekdays: [])

    var isEveryDay: Bool { weekdays.isEmpty }

    init(weekdays: Set<Int>) {
        self.weekdays = weekdays.filter { (1...7).contains($0) }
    }

    // MARK: storage

    /// Round-trips through the raw string the model persists, e.g. "2,4,6".
    /// Anything unparseable degrades to every day rather than to nothing — a
    /// corrupt field should over-schedule visibly, not silently empty the week.
    init(raw: String) {
        self.init(weekdays: Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }))
    }

    var raw: String { weekdays.sorted().map(String.init).joined(separator: ",") }

    // MARK: the question the planner asks

    func isDue(on date: Date, calendar: Calendar = .current) -> Bool {
        isEveryDay || weekdays.contains(calendar.component(.weekday, from: date))
    }

    /// How many due days have gone by since this was last done, counting `date`
    /// itself. Feeds the prompt's neglect ordering.
    ///
    /// Never done counts every due day in the lookback window, so a newly added
    /// activity sorts as the most neglected without needing a sentinel value —
    /// and the window keeps that honest rather than unbounded.
    func daysOverdue(since lastCompleted: Date?,
                     on date: Date,
                     calendar: Calendar = .current,
                     lookbackDays: Int = 28) -> Int {
        let today = calendar.startOfDay(for: date)
        let floor = calendar.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        // Count from the day AFTER it was last done: the day you did it is not
        // a day you owe.
        var cursor = lastCompleted.map { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) ?? today } ?? floor
        if cursor < floor { cursor = floor }

        var count = 0
        while cursor <= today {
            if isDue(on: cursor, calendar: calendar) { count += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return count
    }

    // MARK: display

    /// Ordered Monday-first, matching the chip strip on the routine row rather
    /// than Foundation's Sunday-first numbering.
    static let orderedWeekdays = [2, 3, 4, 5, 6, 7, 1]

    static func shortLabel(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "Sun"
        case 2: return "Mon"
        case 3: return "Tue"
        case 4: return "Wed"
        case 5: return "Thu"
        case 6: return "Fri"
        default: return "Sat"
        }
    }

    /// Single letters for the seven-chip strip, Monday-first.
    static let initials = ["M", "T", "W", "T", "F", "S", "S"]

    var description: String {
        if isEveryDay { return "Every day" }
        if weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if weekdays == [1, 7] { return "Weekends" }
        return Self.orderedWeekdays.filter(weekdays.contains).map(Self.shortLabel).joined(separator: ", ")
    }
}
