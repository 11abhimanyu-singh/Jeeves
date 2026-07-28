//
//  GoogleCalendarTests.swift
//  JeevesTests
//
//  Exercises GoogleCalendarService.parse against real Calendar-API payload
//  shapes — timed, all-day, and multi-day all-day — with no network or token.
//  This is the self-test for calendar handling: run it instead of round-tripping
//  through the phone.
//

import XCTest
@testable import Jeeves

final class GoogleCalendarTests: XCTestCase {

    /// A gregorian calendar pinned to IST so minute-of-day assertions are stable
    /// regardless of the machine's timezone.
    private var ist: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    func testParsesTimedAndAllDayEvents() {
        // Exactly the JSON shapes the Google Calendar v3 API returns.
        let json = data("""
        { "items": [
          { "summary": "Dentist", "location": "MG Road",
            "start": {"dateTime": "2026-08-15T14:00:00+05:30"},
            "end":   {"dateTime": "2026-08-15T15:00:00+05:30"} },
          { "summary": "Independence Day",
            "start": {"date": "2026-08-15"}, "end": {"date": "2026-08-16"} },
          { "summary": "Conference",
            "start": {"date": "2026-08-14"}, "end": {"date": "2026-08-17"} }
        ] }
        """)
        let events = GoogleCalendarService.parse(json, calendar: ist)

        XCTAssertEqual(events.count, 3, "all-day events must NOT be dropped")

        // 1) Timed event.
        XCTAssertEqual(events[0].title, "Dentist")
        XCTAssertFalse(events[0].isAllDay)
        XCTAssertEqual(events[0].startMinute, 14 * 60)   // 14:00 IST
        XCTAssertEqual(events[0].endMinute, 15 * 60)
        XCTAssertEqual(events[0].location, "MG Road")

        // 2) Single-day all-day event.
        XCTAssertEqual(events[1].title, "Independence Day")
        XCTAssertTrue(events[1].isAllDay, "a `date`-based event must be flagged all-day")

        // 3) Multi-day all-day event.
        XCTAssertEqual(events[2].title, "Conference")
        XCTAssertTrue(events[2].isAllDay)
    }

    func testAllDayEventWithNoDateTimeStillParses() {
        let json = data("""
        { "items": [ { "summary": "On leave", "start": {"date": "2026-08-15"}, "end": {"date": "2026-08-16"} } ] }
        """)
        let events = GoogleCalendarService.parse(json, calendar: ist)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isAllDay)
        XCTAssertEqual(events[0].title, "On leave")
    }

    func testMissingSummaryAndEmptyPayload() {
        // No summary → default title; empty items → no events; junk → no crash.
        XCTAssertEqual(
            GoogleCalendarService.parse(data("""
            {"items":[{"start":{"date":"2026-08-15"},"end":{"date":"2026-08-16"}}]}
            """), calendar: ist).first?.title, "Untitled event")
        XCTAssertTrue(GoogleCalendarService.parse(data("{\"items\":[]}"), calendar: ist).isEmpty)
        XCTAssertTrue(GoogleCalendarService.parse(data("not json"), calendar: ist).isEmpty)
    }
}
