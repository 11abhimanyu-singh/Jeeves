//
//  MorningPrompt.swift
//  Jeeves
//
//  What Jeeves offers you at 07:00, and what it does NOT do.
//
//  The old shape: a background task planned the next four days while you slept,
//  and you met a finished plan you had never agreed to. Adherence across the
//  last five planned days was 0%, 0%, 0%, 13%, 36% — the planner had become
//  very good at producing days nobody had chosen.
//
//  The new shape: at 07:00 a list of what is DUE arrives in chat. You tick what
//  you are actually doing, bin what shouldn't be there, confirm anything with a
//  real time, and only then does Jeeves plan. Ignore it and the day stays
//  unplanned — that is the point, not a gap. A plan exists because you picked
//  it or it does not exist at all.
//

import Foundation

enum MorningPrompt {

    /// One row in the morning list.
    struct Candidate: Identifiable, Equatable {
        var id: String { name }
        /// The planner name, which is also what the plan block will be called.
        let name: String
        let minutes: Int
        let tier: PriorityTier
        /// Ticked when the list arrives. Everything due is ticked; the user
        /// unticks rather than hunts.
        let dueToday: Bool
    }

    /// What to offer for `date`: the routine, narrowed to what its cadence says
    /// is due, in fill order.
    ///
    /// Gym parts are excluded — the gym is one anchor placed at a time you
    /// confirm, not a set of activities to tick. Rows that are switched off in
    /// the routine never appear at all: "I don't do this" is a different
    /// statement from "not today", and only the second belongs in a morning
    /// list.
    static func candidates(routine: [RoutineActivity], on date: Date) -> [Candidate] {
        routine
            .filter { $0.enabled && $0.group != .gym }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { Candidate(name: $0.plannerName, minutes: $0.durationMinutes,
                             tier: $0.tier, dueToday: $0.cadence.isDue(on: date)) }
    }

    /// The notification body. It names a COUNT so it can be declined honestly —
    /// "good morning, shall we plan?" is a nag; "6 activities" is information.
    /// Nil means say nothing: a day with nothing due has no offer to make, and
    /// waking someone to tell them so is the app talking to itself.
    static func notificationBody(dueCount: Int, gymAt: Int?) -> String? {
        guard dueCount > 0 || gymAt != nil else { return nil }
        let gym = gymAt.map { " Gym at \(GeneratedBlock.hhmm($0))." } ?? ""
        guard dueCount > 0 else {
            return "Nothing in the routine falls today.\(gym) Tap if you want to add something."
        }
        return "\(dueCount) activit\(dueCount == 1 ? "y" : "ies") due today.\(gym) Tell me which ones and I'll build the day."
    }

    /// The message Jeeves posts into chat. Written as an offer, not an
    /// instruction — the list is the interface, this is just the sentence above
    /// it.
    static func chatOpener(dueCount: Int, totalMinutes: Int, freeMinutes: Int) -> String {
        guard dueCount > 0 else {
            return "Nothing in your routine falls today. Add something below if you want it, or leave the day open."
        }
        let over = totalMinutes > freeMinutes
        let shape = over
            ? "That's \(duration(totalMinutes)) against \(duration(freeMinutes)) free, so something will have to come off."
            : "\(duration(totalMinutes)) of \(duration(freeMinutes)) free."
        return "Here's what's due today. \(shape) Untick what you're not doing, bin anything that shouldn't be on the list."
    }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }

    /// Minutes genuinely available between the day's start and the work
    /// boundary, minus whatever the gym and its trips will take.
    static func freeMinutes(gymAt: Int?, gymSpanMinutes: Int) -> Int {
        let window = DayPlanner.dayEndMinute - DayPreferences.dayStartMinute
        return max(0, window - (gymAt == nil ? 0 : gymSpanMinutes))
    }
}
