//
//  EventKitMappingTests.swift
//  JeevesTests
//
//  The rules that differ between calendar providers, pinned.
//
//  EventKit is read through a real EKEventStore, so these build EKEvents
//  against an in-memory store and exercise the pure mapping. What they protect
//  is the two things that are silently wrong rather than loudly broken: the
//  all-day end date (Google's is EXCLUSIVE, EventKit's is not) and identity
//  (the same meeting in two accounts must become one row).
//

import XCTest
import EventKit
@testable import Jeeves

final class EventKitMappingTests: XCTestCase {

    private let store = EKEventStore()

    private func day(_ y: Int, _ m: Int, _ d: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d,
                                                   hour: hour, minute: minute))!
    }

    private func event(title: String, start: Date, end: Date,
                       allDay: Bool = false, location: String? = nil) -> EKEvent {
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = end
        e.isAllDay = allDay
        e.location = location
        return e
    }

    // MARK: times

    func testATimedEventKeepsItsMinutes() throws {
        let e = event(title: "Appointment with Dr Rao",
                      start: day(2026, 8, 4, 16, 0), end: day(2026, 8, 4, 19, 0))
        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        XCTAssertEqual(mapped.title, "Appointment with Dr Rao")
        XCTAssertEqual(mapped.startMinute, 16 * 60)
        XCTAssertEqual(mapped.endMinute, 19 * 60)
        XCTAssertFalse(mapped.isAllDay)
    }

    /// THE off-by-one. Google's all-day `end` is exclusive, so its importer
    /// subtracts a day; EventKit's endDate is the end of the FINAL day, so
    /// subtracting would lose one. A three-day trip must read as three days.
    func testAnAllDaySpanCoversItsLastDay() throws {
        let e = event(title: "Bhadra Tiger Reserve",
                      start: day(2026, 8, 15), end: day(2026, 8, 17, 23, 59),
                      allDay: true)
        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        XCTAssertTrue(mapped.isAllDay)
        XCTAssertEqual(mapped.startDay, day(2026, 8, 15))
        XCTAssertEqual(mapped.endDay, day(2026, 8, 17),
                       "17 Aug is covered — EventKit's end is inclusive of that day")
        XCTAssertEqual(mapped.spanDays, 3, "15th, 16th, 17th")
    }

    func testASingleDayEventSpansOneDay() throws {
        let e = event(title: "Standup",
                      start: day(2026, 8, 4, 9, 30), end: day(2026, 8, 4, 10, 0))
        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        XCTAssertEqual(mapped.spanDays, 1)
    }

    // MARK: midnight — the webinar that looked like a trip

    /// A 22:30–00:00 online talk occupies two calendar dates. Taking the span
    /// from those dates made it "2 days with a location", which is the exact
    /// shape TravelDetection reads as a trip — the app offered to switch two
    /// days into travel mode for a webinar.
    func testAMeetingEndingAtMidnightIsOneDay() throws {
        let e = event(title: "[Agentic Certification] Evals: Why Agents Fail Silently",
                      start: day(2026, 8, 4, 22, 30), end: day(2026, 8, 5, 0, 0))
        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        XCTAssertEqual(mapped.spanDays, 1, "one late meeting, not a two-day trip")
        XCTAssertEqual(mapped.startDay, day(2026, 8, 4))
        XCTAssertEqual(mapped.endDay, day(2026, 8, 4))
    }

    /// …and it ends at 24:00, not 00:00. Midnight as minute 0 put the end
    /// BEFORE the start — a negative-length block to everything downstream.
    func testAMidnightEndIsTwentyFourHundredNotZero() throws {
        let e = event(title: "Late webinar",
                      start: day(2026, 8, 4, 22, 30), end: day(2026, 8, 5, 0, 0))
        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        XCTAssertEqual(mapped.startMinute, 22 * 60 + 30)
        XCTAssertEqual(mapped.endMinute, 24 * 60)
        XCTAssertGreaterThan(mapped.endMinute, mapped.startMinute,
                             "an event cannot end before it starts")
    }

    func testAMeetingRunningIntoTheSmallHoursIsStillOneDay() throws {
        let e = event(title: "Very late call",
                      start: day(2026, 8, 4, 23, 0), end: day(2026, 8, 5, 1, 30))
        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        XCTAssertEqual(mapped.spanDays, 1)
    }

    /// The genuine article still spans: a conference really does run days.
    func testSomethingLongerThanADayStillSpans() throws {
        let e = event(title: "Offsite",
                      start: day(2026, 8, 4, 9, 0), end: day(2026, 8, 6, 17, 0))
        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        XCTAssertEqual(mapped.spanDays, 3, "9am Tue to 5pm Thu is three days")
    }

    // MARK: a joining link is not a place

    /// Invites put the join URL in the location field. Stored as an address it
    /// becomes somewhere to COMMUTE to — and with a span, somewhere to travel
    /// to. There is no commute to a webinar.
    func testAJoinLinkIsNotAnAddress() throws {
        let e = event(title: "Evals webinar",
                      start: day(2026, 8, 4, 22, 30), end: day(2026, 8, 5, 0, 0),
                      location: "https://maven.com/s/joinlive/094cc22cc3")
        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        XCTAssertEqual(mapped.location, "", "no address means no commute and no trip")
    }

    func testCommonMeetingHostsAreAllTreatedAsOnline() {
        for link in ["https://zoom.us/j/123", "https://teams.microsoft.com/l/meetup-join/x",
                     "https://meet.google.com/abc-defg-hij", "http://maven.com/s/joinlive/1"] {
            XCTAssertTrue(EventKitService.isOnlineMeetingLink(link), link)
        }
    }

    /// A Maps link genuinely names a place, and the app already resolves it.
    func testAMapsLinkIsStillAPlace() {
        XCTAssertFalse(EventKitService.isOnlineMeetingLink("https://maps.app.goo.gl/abc123"))
        XCTAssertFalse(EventKitService.isOnlineMeetingLink("Tasvaa Skin And Hair Clinic"))
    }

    // MARK: identity

    /// Two Outlook accounts invited to one meeting hand back two EKEvents with
    /// the SAME external identifier. Using it as the externalID is what makes
    /// the existing upsert collapse them — no separate dedup pass.
    func testTheExternalIdentifierIsNamespacedForUpsert() throws {
        let e = event(title: "Design review",
                      start: day(2026, 8, 4, 11, 0), end: day(2026, 8, 4, 12, 0))
        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        if let id = e.calendarItemExternalIdentifier {
            XCTAssertEqual(mapped.externalID, "ek:\(id)",
                           "prefixed so an EventKit id can never collide with a Google one")
        } else {
            XCTAssertTrue(mapped.externalID.isEmpty,
                          "no identifier is better than a made-up one")
        }
    }

    // MARK: what must not become an event

    func testAnUntitledEventIsSkipped() {
        let e = event(title: "", start: day(2026, 8, 4, 9, 0), end: day(2026, 8, 4, 10, 0))
        XCTAssertNil(EventKitService.calendarEvent(from: e),
                     "a nameless block on the day helps nobody")
    }

    func testWhitespaceOnlyTitleIsSkipped() {
        let e = event(title: "   ", start: day(2026, 8, 4, 9, 0), end: day(2026, 8, 4, 10, 0))
        XCTAssertNil(EventKitService.calendarEvent(from: e))
    }

    // MARK: location

    func testAPlainLocationIsCarried() throws {
        let e = event(title: "Clinic", start: day(2026, 8, 4, 16, 0), end: day(2026, 8, 4, 17, 0),
                      location: "Tasvaa Skin And Hair Clinic")
        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        XCTAssertEqual(mapped.location, "Tasvaa Skin And Hair Clinic")
    }

    /// No pin from the calendar means the geocoder still has to run — the
    /// fields stay nil rather than being invented.
    func testNoStructuredLocationLeavesTheCoordinatesUnset() throws {
        let e = event(title: "Clinic", start: day(2026, 8, 4, 16, 0), end: day(2026, 8, 4, 17, 0),
                      location: "Somewhere vague")
        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        XCTAssertNil(mapped.latitude)
        XCTAssertNil(mapped.longitude)
    }

    /// A calendar that DID carry a pin answers the question the geocoder would
    /// have been asked — the failure mode being a venue name that resolves to
    /// the wrong city.
    func testAStructuredLocationSuppliesThePin() throws {
        let e = event(title: "Clinic", start: day(2026, 8, 4, 16, 0), end: day(2026, 8, 4, 17, 0))
        let structured = EKStructuredLocation(title: "Tasvaa Skin And Hair Clinic")
        structured.geoLocation = CLLocation(latitude: 12.9716, longitude: 77.5946)
        e.structuredLocation = structured

        let mapped = try XCTUnwrap(EventKitService.calendarEvent(from: e))
        XCTAssertEqual(mapped.latitude ?? 0, 12.9716, accuracy: 0.0001)
        XCTAssertEqual(mapped.longitude ?? 0, 77.5946, accuracy: 0.0001)
        XCTAssertEqual(mapped.location, "Tasvaa Skin And Hair Clinic",
                       "the structured title stands in when there's no address line")
    }

    // MARK: selection storage

    /// Empty means EVERY calendar — both before the user has chosen and when
    /// they tick them all, so a calendar added next month is included rather
    /// than silently missing.
    func testAnEmptySelectionMeansEveryCalendar() {
        let defaults = UserDefaults.standard
        let saved = EventKitService.selectedCalendarIDs
        defer { EventKitService.selectedCalendarIDs = saved }

        EventKitService.selectedCalendarIDs = []
        XCTAssertTrue(EventKitService.selectedCalendarIDs.isEmpty)
        XCTAssertNotNil(defaults.stringArray(forKey: EventKitService.selectedKey))

        EventKitService.selectedCalendarIDs = ["a", "b"]
        XCTAssertEqual(EventKitService.selectedCalendarIDs, ["a", "b"])
    }
}
