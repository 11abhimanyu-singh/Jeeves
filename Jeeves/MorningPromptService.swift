//
//  MorningPromptService.swift
//  Jeeves
//
//  Delivery for the 07:00 offer: the notification that fires, the tap that
//  lands in chat, and the rule for when there is anything worth saying.
//
//  This REPLACES the overnight auto-planner. That service woke at 04:30, built
//  four days of plans, and committed them — so the user met finished days they
//  had never agreed to, and adherence over the last five was 0%, 0%, 0%, 13%,
//  36%. Nothing here commits a plan. It asks.
//
//  A day covered by a trip gets no offer at all: a trip owns its days, and
//  asking "what shall we do today" on the morning of a flight is the same
//  category of mistake, made politely.
//

import Foundation
import SwiftData
import UserNotifications

extension Notification.Name {
    /// Posted when the user taps the morning offer. ContentView opens chat;
    /// chat posts the card. Nothing here decides what the day contains.
    static let jeevesOpenMorningPrompt = Notification.Name("jeeves.openMorningPrompt")
}

enum MorningPromptService {
    static let hour = 7
    static let minute = 0
    /// How many mornings to keep armed. Small on purpose: iOS holds 64 pending
    /// notifications for the whole app, and the plan's own block nudges are
    /// competing for that budget.
    static let windowDays = 4
    static let idPrefix = "jeeves.morning."
    /// Marks the notification so a tap can be told apart from every other
    /// banner the app schedules.
    static let userInfoKey = "morningPromptDay"
    /// How long after opening the app a late-start offer lands. Long enough
    /// not to collide with the launch animation, short enough to be obviously
    /// a response to opening the app.
    static let catchUpDelay: TimeInterval = 10
    /// The last day an offer was pushed out. Stops the catch-up repeating on
    /// every foregrounding of the same unchosen day.
    static let offeredDayKey = "jeeves.morningOfferedOn"

    // MARK: pure

    static func dayKey(_ day: Date, cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The day a tapped notification is offering, or nil if this banner is
    /// nothing to do with the morning offer.
    ///
    /// Pure, and separate from `NotificationDelegate`, because the delegate
    /// cannot be exercised without a real notification: the ROUTING is the part
    /// worth pinning, and leaving it inline meant the only evidence that
    /// tapping the offer opens chat was that I said so.
    static func offeredDay(inUserInfo info: [AnyHashable: Any]) -> String? {
        guard let day = info[userInfoKey] as? String, !day.isEmpty else { return nil }
        return day
    }

    static func id(for day: Date, cal: Calendar = .current) -> String {
        idPrefix + dayKey(day, cal: cal)
    }

    /// The mornings to arm, today first. Start-of-day, so the caller can look
    /// each one up against plan state and trips.
    static func days(from now: Date, count: Int = windowDays, cal: Calendar = .current) -> [Date] {
        let start = cal.startOfDay(for: now)
        return (0..<max(0, count)).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    /// When the offer for `day` should fire, or nil if that moment has already
    /// passed. Today's 07:00 is gone by 09:00 — arming it anyway would deliver
    /// it immediately, which is how "your morning plan" arrives at lunchtime.
    static func fireDate(for day: Date, now: Date, cal: Calendar = .current) -> Date? {
        guard let fire = cal.date(bySettingHour: hour, minute: minute, second: 0,
                                  of: cal.startOfDay(for: day)) else { return nil }
        return fire > now ? fire : nil
    }

    /// Whether chat should put the card up.
    ///
    /// Three ways to have nothing to say, and all of them are silence rather
    /// than a cheerful empty list: the day is already planned, there is nothing
    /// in the routine to offer, or the card is on screen already.
    static func shouldPost(hasPlan: Bool, candidateCount: Int, alreadyShowing: Bool) -> Bool {
        !hasPlan && candidateCount > 0 && !alreadyShowing
    }

    /// A day you started late still deserves its offer.
    ///
    /// `fireDate` refuses to arm a moment that has already gone — correct, or
    /// "your morning plan" arrives at lunchtime. But the consequence was that
    /// opening the app at 10am produced no offer at all that day, which is
    /// precisely the day that most needs one.
    ///
    /// One state is settled, and everything else is still owed an offer.
    ///
    /// SETTLED means all three: a plan exists, you chose it, and what you chose
    /// wasn't nothing. Miss any one and the day is open —
    ///
    ///   • no plan — including a day just cleared;
    ///   • a plan nobody picked — the overnight planner's leftovers, or one
    ///     built before you had a say, which is what this whole change exists
    ///     to stop counting as your decision;
    ///   • a BLANK day — `.only([])` plus a plan of lunch and free time. This is
    ///     technically a choice, and treating it as a settled one is what kept
    ///     the app silent on the day its owner cleared the board specifically to
    ///     start over. An empty day is the absence of a plan, not a plan; it
    ///     earns exactly one nudge, which the stamp below then closes off.
    static func needsCatchUp(day: Date, now: Date, hasPlan: Bool, chosen: Bool,
                             isBlankDay: Bool = false,
                             lastOfferedDay: String?, cal: Calendar = .current) -> Bool {
        guard cal.isDate(day, inSameDayAs: now) else { return false }
        // Still before 07:00 — the scheduled offer will do its job.
        guard fireDate(for: day, now: now, cal: cal) == nil else { return false }
        let settled = hasPlan && chosen && !isBlankDay
        guard !settled else { return false }
        return lastOfferedDay != dayKey(day, cal: cal)
    }

    // MARK: scheduling

    /// Clears and re-arms the coming mornings. Cheap and idempotent — safe to
    /// call on every foreground, which is what keeps the bodies honest when the
    /// routine or the gym changes.
    @MainActor
    static func reschedule(context: ModelContext, now: Date = Date()) async {
        let centre = UNUserNotificationCenter.current()
        let pending = await centre.pendingNotificationRequests().map(\.identifier)
        // Sweep the FUTURE mornings only.
        //
        // Sweeping today's as well made the catch-up delete itself: this method
        // runs on both onAppear and the scenePhase change — twice within a few
        // milliseconds on a cold launch — so run one armed today's offer ten
        // seconds out and stamped the day, and run two removed it and then
        // declined to re-create it because the stamp said "already offered".
        // The loop below only ever re-adds FUTURE days, so anything it cannot
        // re-create it must not destroy.
        let today = id(for: Calendar.current.startOfDay(for: now))
        centre.removePendingNotificationRequests(withIdentifiers:
            pending.filter { $0.hasPrefix(idPrefix) && $0 != today })

        guard NotificationService.remindersEnabled, await NotificationService.ensureAuthorized() else { return }

        let routine = (try? context.fetch(FetchDescriptor<RoutineActivity>())) ?? []
        let states = (try? context.fetch(FetchDescriptor<DailyPlanState>())) ?? []

        for day in days(from: now) {
            guard let fire = fireDate(for: day, now: now) else { continue }
            // A trip owns its days.
            guard !TravelGuard.isTravelDay(day, context: context) else { continue }
            let state = states.first { $0.date.startOfDay == day.startOfDay }
            // Already decided? Then this is a plan, not a question.
            guard state?.plan == nil else { continue }

            let due = MorningPrompt.candidates(routine: routine, on: day).filter(\.dueToday).count
            let gym = (state?.hasGymToday ?? false) ? state?.gymMinute : nil
            guard let body = MorningPrompt.notificationBody(dueCount: due, gymAt: gym) else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Plan today?"
            content.body = body
            content.sound = .default
            content.userInfo = [userInfoKey: dayKey(day)]

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire),
                repeats: false)
            try? await centre.add(UNNotificationRequest(identifier: id(for: day),
                                                        content: content, trigger: trigger))
        }

        await catchUpToday(context: context, now: now, routine: routine, states: states,
                           alreadyArmed: pending.contains(today))
    }

    /// Today's offer, delivered late, when 07:00 has been and gone and the day
    /// still isn't one you chose. At most once per day.
    @MainActor
    private static func catchUpToday(context: ModelContext, now: Date,
                                     routine: [RoutineActivity], states: [DailyPlanState],
                                     alreadyArmed: Bool) async {
        // One is already in flight — adding again would reset its ten seconds
        // every time the app is foregrounded, so it would never actually land.
        guard !alreadyArmed else { return }
        let today = Calendar.current.startOfDay(for: now)
        let state = states.first { $0.date.startOfDay == today }
        guard needsCatchUp(day: today, now: now,
                           hasPlan: state?.plan != nil,
                           chosen: state?.activitySelection.isExplicit ?? false,
                           isBlankDay: state?.activitySelection.isBlankDay ?? false,
                           lastOfferedDay: UserDefaults.standard.string(forKey: offeredDayKey)),
              !TravelGuard.isTravelDay(today, context: context) else { return }

        let due = MorningPrompt.candidates(routine: routine, on: today).filter(\.dueToday).count
        let gym = (state?.hasGymToday ?? false) ? state?.gymMinute : nil
        guard let body = MorningPrompt.notificationBody(dueCount: due, gymAt: gym) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Plan today?"
        content.body = body
        content.sound = .default
        content.userInfo = [userInfoKey: dayKey(today)]

        // Stamp only once the request is genuinely accepted. Stamping first
        // POISONS the day: if the add then fails — or something removes the
        // request before it fires, which is exactly what the old sweep did —
        // the stamp says "already offered" forever and that day can never be
        // offered again. A day that goes silent is worse than one nudged twice.
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: id(for: today), content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: catchUpDelay, repeats: false)))
            UserDefaults.standard.set(dayKey(today), forKey: offeredDayKey)
        } catch {
            EventLog.log(.nudgeScheduled, "FAILED morning offer for \(dayKey(today)): \(error.localizedDescription)",
                         context: context)
        }
    }
}
