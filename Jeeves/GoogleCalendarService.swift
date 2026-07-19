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

        struct Response: Decodable {
            struct Item: Decodable {
                struct When: Decodable { let dateTime: String?; let date: String? }
                let summary: String?
                let location: String?
                let start: When
                let end: When
            }
            let items: [Item]
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parserNoFrac = ISO8601DateFormatter()

        return decoded.items.compactMap { item -> CalendarEvent? in
            // Timed events only — all-day events use `date`, not `dateTime`.
            guard let startStr = item.start.dateTime, let endStr = item.end.dateTime else { return nil }
            let start = parser.date(from: startStr) ?? parserNoFrac.date(from: startStr)
            let end = parser.date(from: endStr) ?? parserNoFrac.date(from: endStr)
            guard let start, let end else { return nil }
            return CalendarEvent(
                title: item.summary ?? "Untitled event",
                startMinute: minuteOfDay(start, cal: cal),
                endMinute: minuteOfDay(end, cal: cal),
                location: item.location ?? ""
            )
        }
    }

    private static func minuteOfDay(_ date: Date, cal: Calendar) -> Int {
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
