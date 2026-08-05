//
//  CalendarEvent.swift
//  Jeeves
//
//  One event, as it arrives from a calendar — before it becomes a DailyEvent.
//
//  It outlived the Google service it was defined in. Every calendar on the
//  phone now arrives through EventKit, so this is the shape the import path
//  speaks, whoever the provider was.
//

import Foundation

struct CalendarEvent: Identifiable {
    let id = UUID()
    let title: String
    let startMinute: Int
    let endMinute: Int
    let location: String
    let isAllDay: Bool
    /// Google's own event id — so a re-sync updates the same record instead of
    /// duplicating it, and so the days of one multi-day event are recognisably
    /// the same event.
    var externalID: String = ""
    /// First and LAST day the event covers, inclusive. Google's all-day `end`
    /// is exclusive, so a "3 Sep → 13 Sep" event really runs 3–12 Sep. Keeping
    /// the span is what lets one sync set up a whole trip instead of a single
    /// orphaned day.
    var startDay: Date? = nil
    var endDay: Date? = nil
    /// The pin, when the source carried one. Google's API does not; EventKit's
    /// structuredLocation does. Set, it spares the app a geocode of the venue
    /// NAME — the lookup whose failure once had a 265 km drive planned as a
    /// 30-minute commute.
    var latitude: Double? = nil
    var longitude: Double? = nil

    /// How many days this event covers (1 for an ordinary event).
    var spanDays: Int {
        guard let startDay, let endDay else { return 1 }
        let d = Calendar.current.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        return max(1, d + 1)
    }
}
