//
//  ActivityTimekeeper.swift
//  Jeeves
//
//  The nudges, and the rule that holds them in a queue.
//
//  Chaining, in the owner's words: at 1:50 a notification says Product
//  Execution is next; at 2:00, if Product Sense is still running, Execution's
//  start notification does NOT come; when Product Sense is stopped at 2:15,
//  it does. So a start nudge is not simply scheduled — it is RELEASED.
//
//  The failure that rule creates is the one worth designing against: a session
//  that never ends holds every remaining notification of the day, and under
//  "no tap means skipped" every one of those blocks then reads as a miss. One
//  forgotten tap would cost the whole day. Two things stop that. A session
//  auto-closes 30 minutes past its planned end, so the chain is never blocked
//  for longer than that. And a block whose nudge was WITHHELD is `unknown`,
//  never `skipped` — the app failed to ask, and recording that as the user's
//  miss is the app blaming them for its own gap.
//

import Foundation
import SwiftData
import UserNotifications

@MainActor
enum ActivityTimekeeper {

    /// How long before a block starts to nudge.
    static let leadMinutes = 10
    /// Past the planned end, ask whether it's still going.
    static let stopNudgeAfter = 15
    /// Past the planned end, give up asking and close it.
    static let autoCloseAfter = 30

    static let startCategory = "jeeves.activity.start"
    static let stopCategory  = "jeeves.activity.stop"
    static let startAction   = "jeeves.activity.startNow"
    static let skipAction    = "jeeves.activity.skip"
    static let continueAction = "jeeves.activity.continue"
    static let stopAction     = "jeeves.activity.stopNow"

    private static let idPrefix = "jeeves.activity."

    /// Notification ids carry the DAY. Two things depended on this and neither
    /// worked without it.
    ///
    /// `clear(for:)` took a date and ignored it, removing every pending nudge
    /// for every day — and it is the first statement of `scheduleDay`, so
    /// planning any day wiped every other day's chain. With a rolling 4-day
    /// auto-plan window that meant today's nudges were deleted about two days
    /// before today began, every day, permanently.
    ///
    /// And `AdherenceEngine.key` is "HH:MM|Title" with no date, so a routine
    /// block at the same time on two days produced the SAME identifier —
    /// committing tomorrow would overwrite today's request on `add` even if the
    /// clear had been scoped. Both halves had to change or nothing fires.
    static func dayPrefix(for date: Date, cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%@%04d%02d%02d.", idPrefix, c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Registered TOGETHER with the workout watchdog's, because
    /// `setNotificationCategories` REPLACES the whole set — registering these
    /// on their own would silently delete "Close it / Still going" from the
    /// stuck-workout nudge.
    static func categories() -> Set<UNNotificationCategory> {
        let start = UNNotificationCategory(
            identifier: startCategory,
            actions: [
                UNNotificationAction(identifier: startAction, title: "Start", options: [.foreground]),
                // Snooze and skip are different answers, and only one of them
                // should mark the block missed.
                UNNotificationAction(identifier: skipAction, title: "Skip", options: [.destructive]),
            ],
            intentIdentifiers: [], options: [])
        let stop = UNNotificationCategory(
            identifier: stopCategory,
            actions: [
                UNNotificationAction(identifier: stopAction, title: "Stop & log", options: [.foreground]),
                UNNotificationAction(identifier: continueAction, title: "Continue", options: []),
            ],
            intentIdentifiers: [], options: [])
        return [start, stop]
    }

    // MARK: scheduling

    /// Schedule the day's start nudges. Blocks after a running session are
    /// withheld — that is the chain.
    static func scheduleDay(plan: GeneratedPlan, on date: Date, context: ModelContext) async {
        await clear(for: date)
        guard NotificationService.remindersEnabled else { return }
        // Requirement: no activity tracking on travel days at all.
        guard !isTravelDay(date, context: context) else { return }
        guard await NotificationService.ensureAuthorized() else { return }

        let cal = Calendar.current
        let now = Date()
        let live = ActivitySession.live(in: context)
        let logged = Set(ActivitySession.onDay(date, in: context).filter { !$0.isLive }.map(\.blockKey))

        for block in plan.blocks {
            guard let unit = ActivityUnit.forBlock(title: block.title, kind: block.kind),
                  let start = block.startMinute else { continue }
            _ = unit
            let key = AdherenceEngine.key(block)
            guard !logged.contains(key), live?.blockKey != key else { continue }

            // THE CHAIN. While something is running, later blocks get nothing.
            // They are released by `releaseChain` when it stops.
            if live != nil {
                markWithheld(key, on: date, context: context)
                continue
            }

            let fireMinute = max(0, start - leadMinutes)
            guard let fireAt = at(fireMinute, on: date, cal: cal), fireAt > now else { continue }
            await schedule(id: "\(dayPrefix(for: date, cal: cal))start.\(key)",
                           title: block.title,
                           body: "Starts in \(leadMinutes) min · \(duration(block)) min planned",
                           category: startCategory, at: fireAt, userInfo: ["blockKey": key])
        }
    }

    /// A session ended — let the queue move. Anything withheld and still ahead
    /// of us is scheduled again; anything already past its time fires now,
    /// which is the "stopped at 2:15, Execution's nudge goes at 2:15" case.
    static func releaseChain(plan: GeneratedPlan, on date: Date, context: ModelContext) async {
        clearWithheld(on: date, context: context)
        await scheduleDay(plan: plan, on: date, context: context)

        // The next block whose start has already passed gets an immediate
        // nudge rather than waiting for a lead time that is behind us.
        guard NotificationService.remindersEnabled,
              !isTravelDay(date, context: context),
              await NotificationService.ensureAuthorized() else { return }
        let now = Date()
        let cal = Calendar.current
        let logged = Set(ActivitySession.onDay(date, in: context).filter { !$0.isLive }.map(\.blockKey))
        let overdue = plan.blocks.first { block in
            guard ActivityUnit.isMeasurable(title: block.title, kind: block.kind),
                  let start = block.startMinute,
                  let startAt = at(start, on: date, cal: cal) else { return false }
            return startAt <= now && !logged.contains(AdherenceEngine.key(block))
        }
        guard let overdue else { return }
        await schedule(id: "\(dayPrefix(for: date, cal: cal))start.now.\(AdherenceEngine.key(overdue))",
                       title: overdue.title,
                       body: "Up next — \(duration(overdue)) min planned",
                       category: startCategory, at: now.addingTimeInterval(2),
                       userInfo: ["blockKey": AdherenceEngine.key(overdue)])
    }

    /// Ask, once, whether a session that has run past its plan is still going.
    ///
    /// Takes VALUES, not the model. Handing a SwiftData object to a detached
    /// task outlives the context that owns it — the task then touches a
    /// destroyed instance and the process dies with "this model instance was
    /// destroyed by calling ModelContext.reset". A notification scheduler has
    /// no business holding a live row anyway.
    static func scheduleStopNudge(blockKey: String, title: String,
                                  plannedMinutes: Int, startedAt: Date) async {
        guard NotificationService.remindersEnabled,
              plannedMinutes > 0,
              await NotificationService.ensureAuthorized() else { return }
        let fireAt = startedAt.addingTimeInterval(Double(plannedMinutes + stopNudgeAfter) * 60)
        guard fireAt > Date() else { return }
        await schedule(id: "\(dayPrefix(for: startedAt))stop.\(blockKey)",
                       title: title,
                       body: "\(stopNudgeAfter) min over. Still going?",
                       category: stopCategory, at: fireAt,
                       userInfo: ["blockKey": blockKey])
    }

    // MARK: the day's account

    /// How long after the productive window closes to ask how it went. Late
    /// enough that the last block has finished, early enough to be answered
    /// before the backfill window shuts at the end of tomorrow.
    static let reviewAfterBoundary = 15

    /// What the end-of-day nudge says.
    ///
    /// Pure, and it counts. "How did today go?" with no number is a nag; the
    /// whole point is that it names how much is actually being asked, so it can
    /// be declined honestly. Nil means say nothing — a day with nothing
    /// assessable has no account to render, and a notification that fires to
    /// report zero of zero is the app talking to itself.
    static func reviewBody(markable: Int, alreadyAnswered: Int) -> String? {
        let left = markable - alreadyAnswered
        guard markable > 0, left > 0 else { return nil }
        if alreadyAnswered == 0 {
            return "\(left) thing\(left == 1 ? "" : "s") to mark — did they happen?"
        }
        return "\(alreadyAnswered) of \(markable) marked · \(left) still open"
    }

    /// Schedule the end-of-day account. Counted at commit time from the plan
    /// itself, because a notification cannot compute anything when it fires.
    static func scheduleDayReview(plan: GeneratedPlan, on date: Date, context: ModelContext) async {
        guard NotificationService.remindersEnabled,
              !isTravelDay(date, context: context),
              await NotificationService.ensureAuthorized() else { return }

        let markable = plan.blocks.filter {
            ActivityUnit.isMeasurable(title: $0.title, kind: $0.kind)
        }.count
        let answered = Set(ActivitySession.onDay(date, in: context)
            .filter { !$0.isLive }.map(\.blockKey)).count
        guard let body = reviewBody(markable: markable, alreadyAnswered: answered) else { return }

        let cal = Calendar.current
        guard let fireAt = at(DayPlanner.dayEndMinute + reviewAfterBoundary, on: date, cal: cal),
              fireAt > Date() else { return }
        await schedule(id: "\(dayPrefix(for: date, cal: cal))review",
                       title: "How did today go?",
                       body: body, category: startCategory, at: fireAt, userInfo: [:])
    }

    // MARK: the backstop

    /// Close anything left running past its plan + 30. Local notifications
    /// can't run code, so this is applied when the app next becomes active —
    /// the same opportunistic sweep WorkoutWatchdog uses.
    @discardableResult
    static func sweepStale(context: ModelContext, now: Date = Date()) -> [ActivitySession] {
        let live = ((try? context.fetch(FetchDescriptor<ActivitySession>())) ?? []).filter(\.isLive)
        var closed: [ActivitySession] = []
        for session in live where shouldAutoClose(session, now: now) {
            ActivityTracker.autoClose(session, context: context)
            closed.append(session)
        }
        return closed
    }

    /// Pure, so the threshold is tested rather than trusted.
    nonisolated static func shouldAutoClose(_ session: ActivitySession, now: Date) -> Bool {
        guard session.plannedMinutes > 0 else {
            // No plan to run past: fall back to the watchdog's four hours.
            return now.timeIntervalSince(session.startedAt) >= WorkoutWatchdog.closeAfter
        }
        let deadline = session.startedAt
            .addingTimeInterval(Double(session.plannedMinutes + autoCloseAfter) * 60)
        return now >= deadline
    }

    // MARK: withheld blocks — asked-or-not, which decides unknown vs skipped

    static func markWithheld(_ key: String, on date: Date, context: ModelContext) {
        let state = DailyPlanState.forDay(date, in: context)
        var keys = state.withheldKeys
        guard keys.insert(key).inserted else { return }
        state.withheldKeys = keys
        context.saveOrLog("activity.withheld")
    }

    static func clearWithheld(on date: Date, context: ModelContext) {
        let state = DailyPlanState.forDay(date, in: context)
        guard !state.withheldKeys.isEmpty else { return }
        state.withheldKeys = []
        context.saveOrLog("activity.withheld.clear")
    }

    // MARK: helpers

    static func isTravelDay(_ date: Date, context: ModelContext) -> Bool {
        ((try? context.fetch(FetchDescriptor<Trip>())) ?? []).contains { $0.covers(date) }
    }

    private static func duration(_ block: GeneratedBlock) -> Int {
        max(0, (block.endMinute ?? 0) - (block.startMinute ?? 0))
    }

    private static func at(_ minute: Int, on date: Date, cal: Calendar) -> Date? {
        cal.date(bySettingHour: (minute / 60) % 24, minute: minute % 60, second: 0, of: date)
    }

    private static func schedule(id: String, title: String, body: String,
                                 category: String, at fireAt: Date,
                                 userInfo: [String: String]) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = userInfo
        let interval = max(1, fireAt.timeIntervalSinceNow)
        let request = UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Clears ONE day's nudges. It used to take `date` and never read it,
    /// filtering on the bare `jeeves.activity.` prefix and emptying the whole
    /// app. NotificationService.clear(for:) has always been day-scoped, which
    /// is why block reminders survived while the activity chain did not.
    /// Which of the pending ids belong to `date`. Pure, because the whole bug
    /// was one line of filtering that nothing could see: the old version
    /// matched the bare "jeeves.activity." prefix and swept every day.
    static func idsToClear(pending: [String], for date: Date) -> [String] {
        let prefix = dayPrefix(for: date)
        return pending.filter { $0.hasPrefix(prefix) }
    }

    static func clear(for date: Date) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = idsToClear(pending: pending.map(\.identifier), for: date)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
