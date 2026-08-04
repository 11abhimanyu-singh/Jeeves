//
//  GoogleCalendarService.swift
//  Jeeves
//
//  Reads today's events from the user's primary Google Calendar (PRD §5.5.1)
//  using an OAuth access token from GoogleOAuthService. Timed (dateTime)
//  events only — all-day events have no start time to anchor a plan around,
//  so they're skipped. Results are imported as DailyEvents for the user to
//  review/confirm; if an event has no location, that's left blank for the
//  user (or Jeeves) to fill (PRD §5.5.1).
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

enum GoogleCalendarService {
    /// Fetches timed events on `day` from the primary calendar.
    static func events(on day: Date) async throws -> [CalendarEvent] {
        let token = try await GoogleOAuthService.shared.validAccessToken()

        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: day)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        let iso = ISO8601DateFormatter()

        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: iso.string(from: startOfDay)),
            .init(name: "timeMax", value: iso.string(from: endOfDay)),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw GoogleOAuthError.authFailed(msg ?? "Calendar request failed (\(http.statusCode)).")
        }

        return parse(data, calendar: cal)
    }

    /// Pure decode + map of the Calendar API's `items` JSON into CalendarEvents.
    /// Extracted from the network call so it can be unit-tested against real
    /// payloads — INCLUDING all-day events — with no token and no round-trip.
    static func parse(_ data: Data, calendar cal: Calendar = .current) -> [CalendarEvent] {
        struct Response: Decodable {
            struct Item: Decodable {
                struct When: Decodable { let dateTime: String?; let date: String? }
                let id: String?
                let summary: String?
                let location: String?
                let start: When
                let end: When
            }
            let items: [Item]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parserNoFrac = ISO8601DateFormatter()

        return decoded.items.compactMap { item -> CalendarEvent? in
            let title = item.summary ?? "Untitled event"
            // Timed event — has an explicit start/end dateTime.
            if let startStr = item.start.dateTime, let endStr = item.end.dateTime {
                let start = parser.date(from: startStr) ?? parserNoFrac.date(from: startStr)
                let end = parser.date(from: endStr) ?? parserNoFrac.date(from: endStr)
                guard let start, let end else { return nil }
                return CalendarEvent(title: title, startMinute: minuteOfDay(start, cal: cal),
                                     endMinute: minuteOfDay(end, cal: cal),
                                     location: item.location ?? "", isAllDay: false,
                                     externalID: item.id ?? "",
                                     startDay: cal.startOfDay(for: start),
                                     endDay: cal.startOfDay(for: end))
            }
            // All-day event — uses `date`, not `dateTime`. It has no time to anchor
            // a block, so it's carried as an all-day context item (the planner is
            // told about it but never places a timed block for it). Its SPAN is
            // kept: Google's all-day end is exclusive, so "3 Sep → 13 Sep" runs
            // 3–12 Sep, and that range is what turns one sync into a whole trip.
            if let startStr = item.start.date {
                let startDay = dayOnly(startStr, cal: cal)
                let endExclusive = item.end.date.flatMap { dayOnly($0, cal: cal) }
                let lastDay = endExclusive.flatMap {
                    cal.date(byAdding: .day, value: -1, to: $0)
                }
                return CalendarEvent(title: title, startMinute: 0, endMinute: 0,
                                     location: item.location ?? "", isAllDay: true,
                                     externalID: item.id ?? "",
                                     startDay: startDay,
                                     // Never let a malformed end produce a range
                                     // that ends before it starts.
                                     endDay: (lastDay.map { max($0, startDay ?? $0) }) ?? startDay)
            }
            return nil
        }
    }

    /// Parses Google's bare all-day date ("2026-09-13"), which carries no time
    /// and no zone. Also tolerates the full-timestamp form some clients return.
    nonisolated static func dayOnly(_ raw: String, cal: Calendar) -> Date? {
        let datePart = String(raw.prefix(10))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        return f.date(from: datePart).map { cal.startOfDay(for: $0) }
    }

    private static func minuteOfDay(_ date: Date, cal: Calendar) -> Int {
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
