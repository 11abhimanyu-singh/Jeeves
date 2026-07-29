//
//  TravelDetection.swift
//  Jeeves
//
//  Deciding whether a day is TRAVEL or an ordinary day with an appointment on
//  it. The discriminator is how far, not how long: a two-hour consultation
//  twenty minutes away leaves the day intact, while a one-hour arrival six
//  hours away IS the day.
//
//  Everything here is pure, so the rules can be argued with in tests rather
//  than discovered on a morning you're trying not to miss a flight. And it only
//  ever produces a SUGGESTION — travel mode stands the planner down, and doing
//  that to someone silently is worse than any missed detection.
//

import Foundation

enum TravelDetection {

    /// One event, reduced to the facts the rules need.
    nonisolated struct Candidate: Sendable, Equatable {
        var title: String
        var day: Date
        var isAllDay: Bool
        var hasLocation: Bool
        var eventMinutes: Int          // scheduled length; 0 for all-day
        /// One-way journey time, when it could be measured. nil = unknown, and
        /// an unknown is never treated as "far" — we don't guess.
        var journeyMinutes: Int?
        /// How many consecutive days this same event covers (1 = single day).
        var spanDays: Int = 1
    }

    nonisolated struct Suggestion: Sendable, Equatable {
        var title: String              // trip title to propose
        var startDay: Date
        var endDay: Date
        var reason: String             // shown to the user, in their terms
        var isStrong: Bool             // strong = distance/multi-day; weak = a hint
    }

    // Thresholds. Deliberately generous: a wrong prompt costs one tap, a
    // missed one costs a wasted morning.
    static let longJourneyMinutes = 180        // >3 h one way — the day is the journey
    static let roundTripDayMinutes = 600       // >10 h there-and-back + event

    /// Does this day look like travel? Returns the trip worth proposing, or nil
    /// for an ordinary day.
    nonisolated static func suggestion(for candidates: [Candidate],
                                       calendar: Calendar = .current) -> Suggestion? {
        // Strongest first, so the reason the user reads is the real one.
        for c in candidates where c.spanDays > 1 && c.hasLocation {
            let end = calendar.date(byAdding: .day, value: c.spanDays - 1, to: c.day) ?? c.day
            return Suggestion(title: c.title, startDay: c.day, endDay: end,
                              reason: "\"\(c.title)\" runs \(c.spanDays) days with a location — that reads as a trip, not \(c.spanDays) ordinary days.",
                              isStrong: true)
        }
        for c in candidates {
            guard let j = c.journeyMinutes else { continue }
            if j > longJourneyMinutes {
                return Suggestion(title: c.title, startDay: c.day, endDay: c.day,
                                  reason: "\(LeaveBy.hours(j)) each way to \"\(c.title)\". That doesn't fit around a working day — it is the day.",
                                  isStrong: true)
            }
            if 2 * j + c.eventMinutes > roundTripDayMinutes {
                return Suggestion(title: c.title, startDay: c.day, endDay: c.day,
                                  reason: "\(LeaveBy.hours(j)) each way plus \(LeaveBy.hours(c.eventMinutes)) there — about \(LeaveBy.hours(2 * j + c.eventMinutes)) of your day.",
                                  isStrong: true)
            }
        }
        // Weakest signal, and the one most likely to be a birthday or a public
        // holiday: an all-day event that at least names a place.
        for c in candidates where c.isAllDay && c.hasLocation && c.spanDays == 1 {
            return Suggestion(title: c.title, startDay: c.day, endDay: c.day,
                              reason: "\"\(c.title)\" is all day and has a location.",
                              isStrong: false)
        }
        return nil
    }

    /// Group events that are really one multi-day thing: the same title on
    /// consecutive days (how Google delivers an all-day span).
    nonisolated static func spanDays(title: String, days: [Date],
                                     calendar: Calendar = .current) -> Int {
        let sorted = Set(days.map { calendar.startOfDay(for: $0) }).sorted()
        guard let first = sorted.first else { return 0 }
        var run = 1
        var cursor = first
        for d in sorted.dropFirst() {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            if calendar.isDate(d, inSameDayAs: next) { run += 1; cursor = d } else { break }
        }
        return run
    }
}
