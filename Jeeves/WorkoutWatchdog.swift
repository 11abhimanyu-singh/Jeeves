//
//  WorkoutWatchdog.swift
//  Jeeves
//
//  Workouts that never got closed. The anomaly digest surfaced two stuck in
//  `.live` for days — the watch had started them and nothing ever ended them,
//  so they sat there inflating nothing and confusing every check-in that read
//  the day.
//
//  The owner's rule for this app is that anomalies are SURFACED, never
//  silently healed. Auto-closing is the exception they explicitly asked for,
//  and it stays honest about it: nudge at two hours, close at four, log the
//  close as an AppEvent so the daily digest still reports it, and never invent
//  a duration. Four hours after a start we know the session is over; we do NOT
//  know when it actually ended, so the workout closes to `.needsDetail` with
//  its duration left for the user rather than claiming four hours of exercise.
//

import Foundation
import SwiftData
import UserNotifications

enum WorkoutWatchdog {
    /// Nudge after this long still live.
    static let nudgeAfter: TimeInterval = 2 * 60 * 60
    /// Close after this long still live.
    static let closeAfter: TimeInterval = 4 * 60 * 60

    static let category = "jeeves.workout.stuck"
    static let closeAction = "jeeves.workout.close"
    static let keepAction = "jeeves.workout.keep"

    /// The notification's actions — registered once at launch so "Close it"
    /// works straight from the banner without opening the app.
    static func registerCategory() {
        let close = UNNotificationAction(identifier: closeAction, title: "Close it",
                                         options: [.destructive])
        let keep = UNNotificationAction(identifier: keepAction, title: "Still going",
                                        options: [])
        let category = UNNotificationCategory(identifier: category,
                                              actions: [close, keep],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// What to do with a workout that is still live, given how long it has
    /// been. Pure, so the thresholds are tested rather than trusted.
    enum Verdict: Equatable { case leaveAlone, nudge, close }

    nonisolated static func verdict(startedAt: Date, now: Date) -> Verdict {
        let open = now.timeIntervalSince(startedAt)
        if open >= closeAfter { return .close }
        if open >= nudgeAfter { return .nudge }
        return .leaveAlone
    }

    /// Body text for the nudge. Pure so the wording is pinned by a test.
    nonisolated static func nudgeBody(title: String, openMinutes: Int) -> String {
        let hours = openMinutes / 60
        let mins = openMinutes % 60
        let spell = hours > 0 ? (mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h") : "\(mins)m"
        let name = title.isEmpty ? "Your workout" : title
        return "\(name) has been running for \(spell). Close it if you're done — "
            + "I'll close it myself after 4 hours."
    }

    /// Sweeps every live workout: nudges the ones past two hours, closes the
    /// ones past four. Safe to call repeatedly — the nudge is scheduled by a
    /// stable identifier so it can't stack up, and closing is idempotent.
    ///
    /// Runs on foreground rather than only at start-time, so a workout that
    /// went stale while the app was closed is still caught.
    @MainActor
    static func sweep(context: ModelContext, now: Date = Date(),
                      notify: Bool = true) async {
        let live = ((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
            .filter { $0.state == .live }
        for workout in live {
            switch verdict(startedAt: workout.date, now: now) {
            case .leaveAlone:
                continue

            case .nudge:
                guard notify else { continue }
                let openMinutes = Int(now.timeIntervalSince(workout.date) / 60)
                await scheduleNudge(for: workout, openMinutes: openMinutes, context: context)

            case .close:
                // The end time is unknown — say so instead of inventing one.
                workout.state = .needsDetail
                context.saveOrLog("workoutWatchdog.autoClose")
                cancelNudge(for: workout)
                EventLog.log(.workoutAutoClosed,
                             "\(workout.title.isEmpty ? workout.type.rawValue : workout.title) was "
                             + "left open over 4h and was closed automatically — its end time and "
                             + "duration are unknown and need confirming",
                             subject: workout.id, context: context)
                if notify { await notifyClosed(workout) }
            }
        }
    }

    @MainActor
    private static func scheduleNudge(for workout: Workout, openMinutes: Int,
                                      context: ModelContext) async {
        guard NotificationService.remindersEnabled,
              await NotificationService.ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Still working out?"
        content.body = nudgeBody(title: workout.title, openMinutes: openMinutes)
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["workoutID": workout.id.uuidString]
        // Fires effectively now; the stable id means re-sweeping replaces the
        // pending one rather than queueing a second banner.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: nudgeID(workout),
                                            content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
        EventLog.log(.nudgeScheduled,
                     "asked whether \(workout.title.isEmpty ? "the workout" : workout.title) is still running",
                     subject: workout.id, context: context)
    }

    @MainActor
    private static func notifyClosed(_ workout: Workout) async {
        guard NotificationService.remindersEnabled,
              await NotificationService.ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Workout closed"
        content.body = "\(workout.title.isEmpty ? "A workout" : workout.title) was open for over "
            + "4 hours, so I closed it. Add the real duration when you get a moment."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "jeeves.workout.closed.\(workout.id.uuidString)",
                                  content: content, trigger: trigger))
    }

    static func nudgeID(_ workout: Workout) -> String {
        "jeeves.workout.stuck.\(workout.id.uuidString)"
    }

    static func cancelNudge(for workout: Workout) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [nudgeID(workout)])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [nudgeID(workout)])
    }

    /// Closes one workout by id — what the notification's "Close it" button
    /// calls. Same honesty as the automatic path: state only, no invented
    /// duration.
    @MainActor
    static func close(workoutID: UUID, context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        guard let workout = all.first(where: { $0.id == workoutID }), workout.state == .live else { return }
        workout.state = .needsDetail
        context.saveOrLog("workoutWatchdog.userClose")
        cancelNudge(for: workout)
        EventLog.log(.workoutAutoClosed,
                     "\(workout.title.isEmpty ? "workout" : workout.title) closed from the reminder",
                     subject: workout.id, context: context)
    }
}
