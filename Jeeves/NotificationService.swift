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

    // MARK: Pure helpers (unit-tested)

    /// Which blocks are worth a reminder — anchors (events, gym, focus reading)
    /// plus commute departures. Filler like "Free time" is skipped.
    static func shouldRemind(_ block: GeneratedBlock) -> Bool {
        if block.isAnchor { return true }
        return ["commute", "event", "gym"].contains(block.kind.lowercased())
    }

    /// The reminder text for a block.
    static func reminderBody(for block: GeneratedBlock) -> String {
        switch block.kind.lowercased() {
        case "commute": return "Time to leave — \(block.title)"
        case "event":   return "\(block.title) — starting now"
        default:        return block.title
        }
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
        clear(for: date)
        guard remindersEnabled, await ensureAuthorized() else { return }

        let cal = Calendar.current
        let now = Date()
        let dayComps = cal.dateComponents([.year, .month, .day], from: date)
        let prefix = idPrefix(for: date)
        var index = 0

        for block in plan.blocks {
            guard shouldRemind(block), let start = block.startMinute else { continue }
            var comps = dayComps
            comps.hour = start / 60
            comps.minute = start % 60
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

    static func clear(for date: Date) {
        let prefix = idPrefix(for: date)
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }

    static func clearAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // MARK: Private

    private static func ensureAuthorized() async -> Bool {
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
