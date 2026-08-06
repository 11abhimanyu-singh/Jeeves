//
//  AdherenceHistory.swift
//  Jeeves
//
//  The SwiftData glue that turns the adherence record into an adaptive planning
//  signal. AdherenceEngine stays pure (it works on plans + outcomes); this
//  reaches into the store to assemble recent days' effective outcomes — auto-
//  inferred from the logs AND the user's manual marks on every block — so the
//  planner can learn what actually gets done and adapt future days to it.
//

import Foundation
import SwiftData

enum AdherenceHistory {
    /// Recent days that have a committed plan, strictly before `date`,
    /// most-recent first and capped at `count`, each paired with its effective
    /// outcomes (log-inferred, with the user's manual marks winning).
    static func recentOutcomes(context: ModelContext, endingBefore date: Date, count: Int = 7)
        -> [(plan: GeneratedPlan, outcomes: [BlockOutcome])] {
        let cutoff = date.startOfDay
        let states = ((try? context.fetch(FetchDescriptor<DailyPlanState>())) ?? [])
            .filter { $0.date.startOfDay < cutoff && $0.plan != nil }
            .sorted { $0.date > $1.date }
            .prefix(count)
        guard !states.isEmpty else { return [] }

        // Fetch each log type once; evidence() slices per day.
        let checkins = (try? context.fetch(FetchDescriptor<CheckIn>())) ?? []
        let prep = (try? context.fetch(FetchDescriptor<PrepSession>())) ?? []
        let jobs = (try? context.fetch(FetchDescriptor<JobApplication>())) ?? []
        let reading = (try? context.fetch(FetchDescriptor<ReadingLog>())) ?? []
        let leisure = (try? context.fetch(FetchDescriptor<LeisureLog>())) ?? []

        return states.compactMap { state -> (GeneratedPlan, [BlockOutcome])? in
            guard let plan = state.plan else { return nil }
            let ev = evidence(day: state.date, checkins: checkins, prep: prep, jobs: jobs, reading: reading, leisure: leisure)
            let inferred = AdherenceEngine.infer(plan: plan, evidence: ev)
            let effective = AdherenceEngine.effective(plan: plan, inferred: inferred, manual: state.manualOutcomes)
            return (plan, effective)
        }
    }

    /// The adaptive-planning note for `date`, distilled from recent adherence.
    /// Nil when there isn't enough history to say anything useful yet.
    static func planningNote(context: ModelContext, for date: Date) -> String? {
        let days = recentOutcomes(context: context, endingBefore: date)
        guard !days.isEmpty else { return nil }
        // Not cadence-filtered, and deliberately so: this is a tier lookup over
        // many past days, not a plan for one. Narrowing it to a single day's
        // due list would mis-weight every other day in the history.
        let routine = Baseline.routine(from: (try? context.fetch(FetchDescriptor<RoutineActivity>())) ?? [])
        return AdherenceEngine.adherenceNote(AdherenceEngine.history(days), routine: routine)
    }

    /// The day's ground-truth evidence, reduced from its logs. Shared by the
    /// live adherence card and the history builder so the two never drift.
    static func evidence(day: Date, checkins: [CheckIn], prep: [PrepSession],
                         jobs: [JobApplication], reading: [ReadingLog], leisure: [LeisureLog],
                         sessions: [ActivitySession] = [],
                         neverAsked: Set<String> = []) -> DayEvidence {
        let cal = Calendar.current
        var e = DayEvidence()
        if let c = checkins.first(where: { cal.isDate($0.date, inSameDayAs: day) }) { e.workedOut = c.workedOut }
        e.prepCategoriesLogged = Set(prep.filter { cal.isDate($0.date, inSameDayAs: day) }.map(\.category))
        e.appliedToJobs = jobs.contains { cal.isDate($0.date, inSameDayAs: day) && $0.appliedToday }
        e.readToday = reading.contains { cal.isDate($0.date, inSameDayAs: day) }
        e.leisureLogged = Set(leisure.filter { cal.isDate($0.date, inSameDayAs: day) }.map(\.activity))
        e.sessionsCompleted = Set(sessions
            .filter { cal.isDate($0.day, inSameDayAs: day) && $0.state == .done }
            .map(\.blockKey))
        e.neverAsked = neverAsked
        return e
    }
}
