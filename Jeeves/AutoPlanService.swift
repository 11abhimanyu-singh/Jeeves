//
//  AutoPlanService.swift
//  Jeeves
//
//  Pre-builds the coming days' plans so the user wakes up to a ready schedule
//  instead of tapping "Plan my day" every morning. Two triggers, because iOS
//  background execution is opportunistic, not guaranteed:
//
//    • A BGProcessingTask armed for the early morning (planning 4 days is
//      several Claude + Maps round-trips — far past a 30-second app-refresh
//      budget, so this uses the longer processing task with network required).
//    • A foreground backstop (ContentView) that fills any missing upcoming day
//      the moment the app opens — so even if the system never granted the
//      overnight slot, today's plan is there when they look.
//
//  It only ever FILLS gaps: a day that already has a committed plan is left
//  untouched, so a plan the user tweaked is never clobbered.
//
//  Requires (Info.plist): BGTaskSchedulerPermittedIdentifiers += taskIdentifier,
//  UIBackgroundModes includes "processing".
//

import Foundation
import BackgroundTasks
import SwiftData
import os

enum AutoPlanService {
    static let taskIdentifier = "abhimanyusingh.me.Jeeves.auto-plan"

    /// How many days ahead to keep planned, today inclusive — a rolling window
    /// so "the next few days" are always ready.
    static let windowDays = 4

    /// After a pass that couldn't fill every gap (the planner was unreachable),
    /// wait this long before trying again — otherwise a persistent outage would
    /// re-run up to `windowDays` doomed ~180s generations on every foregrounding.
    static let failureCooldown: TimeInterval = 30 * 60
    private static let cooldownKey = "autoPlanCooldownUntil"

    // MARK: Which days need a plan (pure, testable)

    /// The days in `[from, from+days)` that have no committed plan yet — the
    /// only days auto-planning should touch. `plannedDays` is the set of
    /// start-of-day dates that already have a stored plan.
    static func daysNeedingPlans(from: Date, days: Int, plannedDays: Set<Date>) -> [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: from)
        return (0..<max(0, days)).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            return plannedDays.contains(day) ? nil : day
        }
    }

    // MARK: Fill the gaps (network)

    /// Generates and commits a plan for every upcoming day that lacks one.
    /// Silent by design — the payoff is the plan simply being there, not a
    /// 4 a.m. notification. Returns how many days it filled.
    @MainActor
    @discardableResult
    static func ensureUpcomingPlans(context: ModelContext, referenceNow: Date = Date()) async -> Int {
        let plans = (try? context.fetch(FetchDescriptor<DailyPlanState>())) ?? []
        let plannedDays = Set(plans.filter { $0.plan != nil }.map { $0.date.startOfDay })
        let needed = daysNeedingPlans(from: referenceNow, days: windowDays, plannedDays: plannedDays)
        guard !needed.isEmpty else {
            // Nothing to do → clear any prior back-off; the window is healthy.
            UserDefaults.standard.removeObject(forKey: cooldownKey)
            return 0
        }
        // Back off after a recent failed pass so a persistent outage doesn't burn
        // minutes of doomed network work on every foregrounding.
        if let until = UserDefaults.standard.object(forKey: cooldownKey) as? Date, referenceNow < until {
            return 0
        }

        let allEvents = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        let locations = (try? context.fetch(FetchDescriptor<SavedLocation>())) ?? []
        let prepSessions = (try? context.fetch(FetchDescriptor<PrepSession>())) ?? []
        let routineActivities = (try? context.fetch(FetchDescriptor<RoutineActivity>())) ?? []
        let routine = Baseline.routine(from: routineActivities)

        var filled = 0
        for day in needed {
            let state = plans.first { $0.date.startOfDay == day } ?? {
                let s = DailyPlanState(date: day, hasGymToday: false, gymMinute: nil)
                context.insert(s); return s
            }()
            let dayEvents = allEvents.filter { $0.date.startOfDay == day }.sorted { $0.startMinute < $1.startMinute }

            // generateLogged (not generate) so every auto-plan attempt — overnight
            // or foreground backstop — leaves a diagnostics trace (trigger
            // .autoPlan), mirrored to iCloud Drive. Without this we can't tell
            // whether the background task ever fired.
            let result = await PlanCoordinator.generateLogged(.init(
                userMessage: "",
                hasGym: state.hasGymToday,
                gymMinute: state.gymMinute,
                events: dayEvents,
                locations: locations,
                prepSessions: prepSessions,
                routine: routine,
                adherenceNote: AdherenceHistory.planningNote(context: context, for: day),
                planDate: day
            ), context: context, trigger: .autoPlan)
            // An offline (deterministic) plan is a poor thing to silently pin
            // for a FUTURE day — leave the gap so the foreground path (or the
            // user) can build a real one once the network is back.
            guard !result.isOffline else { continue }

            state.storePlan(result.plan, isOffline: false)
            context.saveOrLog()
            await NotificationService.reschedule(plan: result.plan, on: day)
            filled += 1
        }
        // If any gap survived (a day fell back to offline / the planner was
        // unreachable), arm the cooldown; a fully-filled window clears it.
        if filled < needed.count {
            UserDefaults.standard.set(referenceNow.addingTimeInterval(failureCooldown), forKey: cooldownKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cooldownKey)
        }
        return filled
    }

    // MARK: Background scheduling

    /// Register the launch handler. MUST run before launch finishes (call from
    /// JeevesApp.init). No-ops if the identifier isn't permitted — the
    /// foreground backstop still covers us.
    @MainActor
    static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            // setTaskCompleted must be called exactly once — on success OR on
            // expiration. Without the expiration call, iOS throttles future
            // background launches; the lock makes the two paths mutually exclusive.
            let completed = OSAllocatedUnfairLock(initialState: false)
            func complete(_ success: Bool) {
                let already = completed.withLock { done -> Bool in defer { done = true }; return done }
                if !already { processing.setTaskCompleted(success: success) }
            }
            let work = Task { @MainActor in
                await ensureUpcomingPlans(context: container.mainContext)
                scheduleNext(context: container.mainContext)   // re-arm for the next morning
                complete(true)
            }
            processing.expirationHandler = { work.cancel(); complete(false) }
        }
    }

    /// Ask iOS to wake the app in the small hours so plans are ready before the
    /// user is. Requires network (the planner calls Claude + Maps).
    static func scheduleNext(context: ModelContext, now: Date = Date()) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nextEarlyMorning(after: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The next ~4:30 a.m. strictly after `now`. Pure so the scheduling window
    /// is unit-testable.
    static func nextEarlyMorning(after now: Date, hour: Int = 4, minute: Int = 30) -> Date {
        let cal = Calendar.current
        let todayTarget = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if todayTarget > now { return todayTarget }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow) ?? tomorrow
    }
}
