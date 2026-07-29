//
//  NotificationService.swift
//  Jeeves
//
//  On-device reminders for the committed day plan. These are LOCAL
//  notifications (UNUserNotificationCenter) — no server, no push certificate,
//  no paid developer account. When a plan is generated for a day, we schedule
//  a reminder at the start of each meaningful block (commute departures, the
//  gym, events, the morning focus block). Re-planning clears and reschedules
//  that day's reminders. Server push would need a backend + paid account and
//  isn't needed for a single-user planner.
//

import Foundation
import UserNotifications
import UIKit

/// Makes reminders appear as banners even while the app is open (iOS hides them
/// in-foreground by default). Set once at launch.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

enum NotificationService {
    static let enabledKey = "jeeves.remindersEnabled"

    /// Call once at app launch so reminders show while the app is in the foreground.
    static func configure() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    /// Fires a reminder ~5s from now so the user can see reminders actually work
    /// on-device (there's no way to push to a physical device from a dev Mac).
    static func sendTestReminder(body: String) async {
        guard await ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Jeeves"
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(identifier: "jeeves-test-\(UUID().uuidString)", content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static var remindersEnabled: Bool {
        // Default on — a plan without reminders isn't much of a plan.
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The banner text for a live traffic re-check. Pure, so it's unit-tested.
    static func commuteUpdateBody(commuteTitle: String, newDepartMinute: Int, earlierByMinutes: Int) -> String {
        let leaveBy = String(format: "%02d:%02d", (newDepartMinute / 60) % 24, newDepartMinute % 60)
        if earlierByMinutes > 0 {
            return "\(commuteTitle): traffic's heavier — leave by \(leaveBy), \(earlierByMinutes) min earlier than planned."
        } else {
            return "\(commuteTitle): traffic's lighter — you can leave by \(leaveBy)."
        }
    }

    /// Tells the user their leave-by time moved after a live traffic re-check.
    @MainActor
    static func notifyCommuteUpdate(commuteTitle: String, newDepartMinute: Int, earlierByMinutes: Int) async {
        guard remindersEnabled, await ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Traffic update"
        content.body = commuteUpdateBody(commuteTitle: commuteTitle, newDepartMinute: newDepartMinute, earlierByMinutes: earlierByMinutes)
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "jeeves-traffic-\(UUID().uuidString)", content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The banner text for a finished plan. Pure, so it's unit-tested.
    static func planReadyBody(isOffline: Bool) -> String {
        isOffline
            ? "Your day is planned (offline) — tap to review it in Jeeves."
            : "Jeeves finished planning your day — tap to view it."
    }

    /// Announces a finished plan with a local notification — but ONLY when the
    /// app isn't in the foreground (if it's on screen, the user already sees the
    /// plan appear, so a banner would be noise). This is what tells the user
    /// "your day is ready" after they backgrounded the app while it planned.
    @MainActor
    static func notifyPlanReady(isOffline: Bool) async {
        guard UIApplication.shared.applicationState != .active else { return }
        guard await ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your day is planned"
        content.body = planReadyBody(isOffline: isOffline)
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "jeeves-plan-ready-\(UUID().uuidString)", content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: Pure helpers (unit-tested)

    /// Which blocks are worth a reminder — anchors (events, gym, focus reading,
    /// sleep) plus commute departures. Filler like "Free time" is skipped.
    static func shouldRemind(_ block: GeneratedBlock) -> Bool {
        if block.isAnchor { return true }
        return ["commute", "event", "gym", "sleep"].contains(block.kind.lowercased())
    }

    /// Minutes of lead time before a block's start that its reminder fires.
    /// Events and sleep get a 10-minute heads-up so you can wrap up and head
    /// out (or wind down); everything else reminds right at its start time.
    static func leadMinutes(for block: GeneratedBlock) -> Int {
        ["event", "sleep"].contains(block.kind.lowercased()) ? 10 : 0
    }

    /// The reminder text for a block. Events/sleep fire 10 min early, so their
    /// copy says so.
    static func reminderBody(for block: GeneratedBlock) -> String {
        switch block.kind.lowercased() {
        case "commute": return "Time to leave — \(block.title)"
        case "event":   return "In 10 min: \(block.title)\(startLabel(block).map { " at \($0)" } ?? "")"
        case "sleep":   return "Wind down — bedtime in 10 min"
        default:        return block.title
        }
    }

    private static func startLabel(_ block: GeneratedBlock) -> String? {
        guard let s = block.startMinute else { return nil }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: Scheduling

    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Clears any existing reminders for `date` and, if enabled and authorized,
    /// schedules fresh ones from the plan. Past times are skipped.
    static func reschedule(plan: GeneratedPlan, on date: Date) async {
        await clear(for: date)
        guard remindersEnabled, await ensureAuthorized() else { return }

        let cal = Calendar.current
        let now = Date()
        let dayComps = cal.dateComponents([.year, .month, .day], from: date)
        let prefix = idPrefix(for: date)
        var index = 0

        for block in plan.blocks {
            guard shouldRemind(block), let start = block.startMinute else { continue }
            let fireMinute = max(0, start - leadMinutes(for: block))
            var comps = dayComps
            comps.hour = fireMinute / 60
            comps.minute = fireMinute % 60
            guard let fireDate = cal.date(from: comps), fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Jeeves"
            content.body = reminderBody(for: block)
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false
            )
            let request = UNNotificationRequest(identifier: "\(prefix)\(index)", content: content, trigger: trigger)
            index += 1
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Async so callers can await removal BEFORE scheduling fresh reminders.
    /// The old callback-based version returned immediately, so reschedule() could
    /// add new same-prefixed requests that the late-firing callback then deleted.
    static func clear(for date: Date) async {
        let prefix = idPrefix(for: date)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }

    static func clearAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // MARK: Private

    // Internal (not private) so TravelNotifier's leave-by nudges run the same
    // authorization path as plan-block reminders instead of silently no-oping.
    static func ensureAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return await requestAuthorization()
        default: return false // denied
        }
    }

    private static func idPrefix(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = .current
        return "jeeves-\(f.string(from: date.startOfDay))-"
    }
}
