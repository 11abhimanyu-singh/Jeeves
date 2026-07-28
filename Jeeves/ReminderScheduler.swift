//
//  ReminderScheduler.swift
//  Jeeves
//
//  Turns Reminder models into local notifications (UNUserNotificationCenter) —
//  no server, no push certificate. Every request Jeeves owns is namespaced with
//  the "reminder-" identifier prefix, so a full reschedule can wipe the old set
//  and lay down a fresh one without touching the day-plan reminders that
//  NotificationService schedules under its own prefix. Authorization is already
//  requested at app launch, so we only add requests here, best-effort.
//

import Foundation
import UserNotifications

enum ReminderScheduler {
    /// Namespaces every request this scheduler owns.
    private static let idPrefix = "reminder-"

    /// Cancels every Jeeves reminder notification, then re-adds one (or, for
    /// weekdays, five) per active reminder. Call after any mutation so the
    /// pending notifications always match the store.
    static func reschedule(_ reminders: [Reminder]) {
        let center = UNUserNotificationCenter.current()
        // Build the fresh requests here, on the caller's actor, reading the model
        // objects now rather than inside the async callback.
        let fresh = reminders.filter(\.isActive).flatMap { requests(for: $0) }
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
            for request in fresh { center.add(request) }   // best-effort
        }
    }

    /// Removes just this reminder's pending notification(s) — the once/daily/
    /// weekly identifier plus every weekdays variant, so it clears regardless of
    /// which recurrence it last used.
    static func cancel(_ reminder: Reminder) {
        let base = "\(idPrefix)\(reminder.id.uuidString)"
        var ids = [base]
        ids.append(contentsOf: (2...6).map { "\(base)-\($0)" })
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Request building

    /// The notification request(s) for one reminder, derived from its fireAt's
    /// date components and recurrence.
    private static func requests(for reminder: Reminder) -> [UNNotificationRequest] {
        let base = "\(idPrefix)\(reminder.id.uuidString)"
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .weekday], from: reminder.fireAt)

        func content() -> UNMutableNotificationContent {
            let c = UNMutableNotificationContent()
            c.title = reminder.title
            c.sound = .default
            return c
        }
        func request(_ id: String, matching match: DateComponents, repeats: Bool) -> UNNotificationRequest {
            let trigger = UNCalendarNotificationTrigger(dateMatching: match, repeats: repeats)
            return UNNotificationRequest(identifier: id, content: content(), trigger: trigger)
        }

        switch reminder.recurrence {
        case .once:
            var m = DateComponents()
            m.year = parts.year; m.month = parts.month; m.day = parts.day
            m.hour = parts.hour; m.minute = parts.minute
            return [request(base, matching: m, repeats: false)]

        case .daily:
            var m = DateComponents()
            m.hour = parts.hour; m.minute = parts.minute
            return [request(base, matching: m, repeats: true)]

        case .weekly:
            var m = DateComponents()
            m.weekday = parts.weekday; m.hour = parts.hour; m.minute = parts.minute
            return [request(base, matching: m, repeats: true)]

        case .weekdays:
            // One repeating request per weekday, Monday(2) through Friday(6).
            return (2...6).map { weekday in
                var m = DateComponents()
                m.weekday = weekday; m.hour = parts.hour; m.minute = parts.minute
                return request("\(base)-\(weekday)", matching: m, repeats: true)
            }
        }
    }
}
