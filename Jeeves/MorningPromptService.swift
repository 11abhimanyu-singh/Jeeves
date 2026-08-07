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

    // MARK: pure

    static func dayKey(_ day: Date, cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
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

    // MARK: scheduling

    /// Clears and re-arms the coming mornings. Cheap and idempotent — safe to
    /// call on every foreground, which is what keeps the bodies honest when the
    /// routine or the gym changes.
    @MainActor
    static func reschedule(context: ModelContext, now: Date = Date()) async {
        let centre = UNUserNotificationCenter.current()
        let pending = await centre.pendingNotificationRequests()
        centre.removePendingNotificationRequests(withIdentifiers:
            pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) })

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
    }
}
