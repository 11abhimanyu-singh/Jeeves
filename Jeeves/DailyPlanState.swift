//
//  DailyPlanState.swift
//  Jeeves
//
//  Persists the one input the planner needs each day: whether there's a
//  gym session, and what time weightlifting starts. Without this, the
//  gym time was just @State and reset every time the app relaunched.
//

import Foundation
import SwiftData

/// Which of the routine's activities a single day is actually for.
///
/// Three states, not two, and the third is the one that matters: a day nobody
/// has chosen for is NOT the same as a day chosen to be empty. "Cancel all
/// activities today and keep the full day free" used to clear the gym, report
/// honestly that there were no events left, and then watch the planner refill
/// the day from the routine — because the routine's `enabled` flag is permanent
/// configuration, and there was nowhere to say "not today".
enum ActivitySelection: Equatable {
    /// No choice made for this day — plan the routine as configured.
    case routine
    /// Exactly these planner names, and nothing else. EMPTY means a
    /// deliberately blank day, which is a real answer.
    case only(Set<String>)

    func includes(_ plannerName: String) -> Bool {
        switch self {
        case .routine:          return true
        case .only(let names):  return names.contains(plannerName)
        }
    }

    /// The user asked for nothing at all today.
    var isBlankDay: Bool { self == .only([]) }

    /// Did the user choose for this day at all?
    var isExplicit: Bool { self != .routine }
}

@Model
final class DailyPlanState {
    var date: Date = Date.distantPast   // startOfDay — one record per day
    var hasGymToday: Bool = false
    var gymMinute: Int?     // minutes-since-midnight for weightlifting start
    var planConfirmed: Bool = false // true once the gym-input tile has been submitted or dismissed

    // The committed day plan for this date (encoded GeneratedPlan). This is what
    // makes "Plan my day" persist — it survives relaunches and shows on the
    // Day Planner, rather than living only in the chat.
    var generatedPlanJSON: String? = nil
    var generatedPlanIsOffline: Bool = false

    // How much of this day's plan was actually followed (0–1), inferred from the
    // day's own logs (and any manual corrections). Nil until assessable.
    var adherenceScore: Double? = nil
    var adherenceAssessed: Int = 0   // how many blocks we could judge

    // Manual done/skipped marks the user tapped, keyed by block (JSON). These
    // override the inferred outcome for that block.
    var manualOutcomesJSON: String? = nil
    /// Block keys whose start nudge the chain WITHHELD because a session was
    /// still running. These were never asked about, so they are `unknown` —
    /// marking them skipped would be the app recording its own gap as the
    /// user's miss.
    var withheldKeysJSON: String? = nil
    /// This day's own activity choice, as planner names. Nil is the third
    /// state — no choice made — and is why this is a JSON string rather than a
    /// stored Set: nil and "[]" have to stay distinguishable.
    var activitySelectionJSON: String? = nil

    /// When something the plan was BUILT FROM changed after it was built.
    ///
    /// Five tools move a planner input — add/delete/edit an event, set the gym,
    /// choose the day's activities — and only the last of them rebuilt the day.
    /// The rest left a plan on screen that disagreed with the events listed
    /// directly above it, and (worse) left its notifications armed: a deleted
    /// appointment still pushed "time to leave". Asking each tool to remember
    /// to re-plan is a request; recording the fact here is a rule, and it costs
    /// one assignment per mutation.
    var planStaleSince: Date? = nil
    /// What changed, in the user's words — "Dentist was cancelled".
    var planStaleReason: String? = nil

    init(date: Date, hasGymToday: Bool, gymMinute: Int?, planConfirmed: Bool = false) {
        self.date = date
        self.hasGymToday = hasGymToday
        self.gymMinute = gymMinute
        self.planConfirmed = planConfirmed
    }

    var plan: GeneratedPlan? {
        guard let generatedPlanJSON, let data = generatedPlanJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GeneratedPlan.self, from: data)
    }

    func storePlan(_ plan: GeneratedPlan, isOffline: Bool) {
        generatedPlanJSON = (try? JSONEncoder().encode(plan)).flatMap { String(data: $0, encoding: .utf8) }
        generatedPlanIsOffline = isOffline
    }

    /// Manual done/skipped marks, decoded (block key → outcome).
    var manualOutcomes: [String: BlockOutcome] {
        guard let json = manualOutcomesJSON, let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.reduce(into: [:]) { if let o = BlockOutcome(rawValue: $1.value) { $0[$1.key] = o } }
    }

    /// Set (or clear, with nil) the manual mark for one block key.
    func setManualOutcome(_ outcome: BlockOutcome?, forKey key: String) {
        var raw = manualOutcomes.mapValues(\.rawValue)
        if let outcome { raw[key] = outcome.rawValue } else { raw[key] = nil }
        manualOutcomesJSON = raw.isEmpty ? nil : (try? JSONEncoder().encode(raw)).flatMap { String(data: $0, encoding: .utf8) }
    }

    var withheldKeys: Set<String> {
        get {
            guard let json = withheldKeysJSON, let data = json.data(using: .utf8),
                  let keys = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
            return keys
        }
        set {
            withheldKeysJSON = newValue.isEmpty ? nil
                : (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    var activitySelection: ActivitySelection {
        get {
            guard let json = activitySelectionJSON, let data = json.data(using: .utf8),
                  let names = try? JSONDecoder().decode(Set<String>.self, from: data)
            else { return .routine }
            return .only(names)
        }
        set {
            switch newValue {
            case .routine:
                activitySelectionJSON = nil
            case .only(let names):
                // Encoded even when empty — "[]" is the blank day, and losing
                // it to nil would hand the day straight back to the routine.
                activitySelectionJSON = (try? JSONEncoder().encode(names))
                    .flatMap { String(data: $0, encoding: .utf8) }
            }
        }
    }

    /// True when this day HAS a plan and that plan predates a change to its
    /// inputs. A day with no plan isn't stale — it's simply unplanned.
    var isPlanStale: Bool { generatedPlanJSON != nil && planStaleSince != nil }

    /// Record that an input moved under the committed plan. No-op when there is
    /// no plan to invalidate, and the FIRST reason wins — the user needs to
    /// know what started the drift, not the most recent thing to touch it.
    func markPlanStale(_ reason: String, at now: Date = Date()) {
        guard generatedPlanJSON != nil else { return }
        if planStaleSince == nil {
            planStaleSince = now
            planStaleReason = reason
        }
    }

    /// Convenience for the timekeeper, which works in day terms.
    static func forDay(_ day: Date, in context: ModelContext) -> DailyPlanState {
        fetchOrCreate(for: day, in: context)
    }

    // MARK: One-record-per-day

    /// The single record for `day`, fetched DIRECTLY from the store (not via an
    /// @Query, which can lag a just-inserted row and let two callers each create
    /// their own duplicate). Creates and inserts one if none exists. CloudKit
    /// forbids `@Attribute(.unique)`, so uniqueness is enforced here in code,
    /// backed by dedupe() at launch.
    static func fetchOrCreate(for day: Date, in context: ModelContext,
                              hasGymToday: Bool = false, gymMinute: Int? = nil) -> DailyPlanState {
        let start = day.startOfDay
        var desc = FetchDescriptor<DailyPlanState>(predicate: #Predicate { $0.date == start })
        desc.fetchLimit = 1
        if let existing = try? context.fetch(desc).first { return existing }
        let created = DailyPlanState(date: start, hasGymToday: hasGymToday, gymMinute: gymMinute)
        context.insert(created)
        return created
    }

    /// Collapse any duplicate per-day rows (from pre-fix races or CloudKit
    /// merges), keeping the richest: a row with a stored plan wins, else a
    /// confirmed one. Run once at launch. Returns how many rows were deleted.
    @discardableResult
    static func dedupe(in context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<DailyPlanState>()) else { return 0 }
        var keeper: [Date: DailyPlanState] = [:]
        var removed = 0
        for row in all {
            let day = row.date.startOfDay
            guard let current = keeper[day] else { keeper[day] = row; continue }
            let rowIsBetter = (row.generatedPlanJSON != nil && current.generatedPlanJSON == nil)
                || (row.planConfirmed && !current.planConfirmed)
            if rowIsBetter { keeper[day] = row; context.delete(current) }
            else { context.delete(row) }
            removed += 1
        }
        if removed > 0 { context.saveOrLog() }
        return removed
    }
}
