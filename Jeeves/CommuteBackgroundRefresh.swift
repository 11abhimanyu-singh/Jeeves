//
//  CommuteBackgroundRefresh.swift
//  Jeeves
//
//  The autonomous half of live commute refresh: asks iOS to wake the app ~90
//  min before the next event-commute so it can re-price that leg against fresh
//  traffic even if the app is closed. iOS grants background time
//  opportunistically (it is NOT a precise timer), so the foreground refresh in
//  ContentView is the reliable backstop; this just makes it proactive when the
//  system cooperates. Everything degrades gracefully — if the task identifier
//  isn't permitted, registration/submission simply no-op.
//
//  Requires (in Info.plist, set via build settings):
//    UIBackgroundModes = [fetch]
//    BGTaskSchedulerPermittedIdentifiers = [taskIdentifier]
//

import Foundation
import BackgroundTasks
import SwiftData
import os

enum CommuteBackgroundRefresh {
    static let taskIdentifier = "abhimanyusingh.me.Jeeves.commute-refresh"

    /// Register the launch handler. MUST run before the app finishes launching
    /// (call from JeevesApp.init). Returns false and no-ops if the identifier
    /// isn't permitted in Info.plist — the foreground refresh still covers us.
    @MainActor
    @discardableResult
    static func register(container: ModelContainer) -> Bool {
        // The launch handler is invoked by the system on a background queue, so
        // it stays non-isolated and hops to the main actor for the actual work.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            // Complete exactly once — success or expiration — or iOS throttles
            // future launches. The lock keeps the two paths mutually exclusive.
            let completed = OSAllocatedUnfairLock(initialState: false)
            func complete(_ success: Bool) {
                let already = completed.withLock { done -> Bool in defer { done = true }; return done }
                if !already { refresh.setTaskCompleted(success: success) }
            }
            let work = Task { @MainActor in
                await CommuteRefresh.run(context: container.mainContext)
                scheduleNext(context: container.mainContext)   // re-arm for the next leg
                complete(true)
            }
            refresh.expirationHandler = { work.cancel(); complete(false) }
        }
    }

    /// Schedule (or re-schedule) a wake ~90 min before today's next event
    /// commute. Call after committing a plan and after each background run.
    @MainActor
    static func scheduleNext(context: ModelContext, now: Date = Date()) {
        let today = now.startOfDay
        guard let state = try? context.fetch(FetchDescriptor<DailyPlanState>(predicate: #Predicate { $0.date == today })).first,
              let plan = state.plan else { return }
        let events = (try? context.fetch(FetchDescriptor<DailyEvent>(predicate: #Predicate { $0.date == today }))) ?? []
        let locations = (try? context.fetch(FetchDescriptor<SavedLocation>())) ?? []
        let cal = Calendar.current
        let nowMinute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        guard let departMinute = CommuteRefresh.nextDepartureMinute(plan: plan, events: events, locations: locations, nowMinute: nowMinute),
              let departDate = cal.date(bySettingHour: departMinute / 60, minute: departMinute % 60, second: 0, of: today) else { return }

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        // Wake ~90 min before departure; if we're already inside that window,
        // ask for the soonest permissible wake instead.
        let ninetyBefore = departDate.addingTimeInterval(-Double(CommuteRefresh.windowMinutes) * 60)
        request.earliestBeginDate = max(ninetyBefore, now.addingTimeInterval(60))
        try? BGTaskScheduler.shared.submit(request)
    }
}
