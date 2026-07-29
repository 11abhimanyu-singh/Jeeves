//
//  ItineraryTests.swift
//  JeevesTests
//
//  Turning messy calendar ranges into an itinerary. The fixture is the user's
//  real calendar, pulled live on 2026-07-29:
//
//    "Bali"                 start 2026-09-03  end 2026-09-13  (exclusive)
//    "Travel to Singapore"  start 2026-09-11  end 2026-09-15  (exclusive)
//
//  So Bali really runs 3–12 Sep and Singapore 11–14 Sep — and they OVERLAP on
//  the 11th and 12th, because a leg was added without trimming the one before.
//  You can't be in two countries, so a later start means you moved.
//

import XCTest
@testable import Jeeves

final class ItineraryTests: XCTestCase {

    private var cal: Calendar { Calendar(identifier: .gregorian) }
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: day))!
    }
    private typealias Span = Itinerary.Span

    // MARK: Google's exclusive end

    func testAllDayEndIsExclusiveSoTheLastDayIsTheDayBefore() {
        // The parse subtracts a day; here we pin the arithmetic the fixture relies on.
        let endExclusive = d(2026, 9, 13)
        let lastDay = cal.date(byAdding: .day, value: -1, to: endExclusive)!
        XCTAssertEqual(cal.startOfDay(for: lastDay), d(2026, 9, 12),
                       "'end 13 Sep' means the trip's last day is the 12th")
    }

    // MARK: The real overlap

    func testOverlappingStaysResolveInFavourOfTheLaterStart() {
        let bali = Span(place: "Bali", start: d(2026, 9, 3), end: d(2026, 9, 12))
        let sing = Span(place: "Travel to Singapore", start: d(2026, 9, 11), end: d(2026, 9, 14))
        let out = Itinerary.resolveOverlaps([bali, sing], calendar: cal)

        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].place, "Bali")
        XCTAssertEqual(out[0].end, d(2026, 9, 10), "Bali is trimmed to the day before the move")
        XCTAssertEqual(out[1].start, d(2026, 9, 11), "Singapore begins on the move day")
        XCTAssertEqual(out[1].end, d(2026, 9, 14))
    }

    func testTheMoveDayIsATransition() {
        let out = Itinerary.resolveOverlaps([
            Span(place: "Bali", start: d(2026, 9, 3), end: d(2026, 9, 12)),
            Span(place: "Singapore", start: d(2026, 9, 11), end: d(2026, 9, 14)),
        ], calendar: cal)
        let moves = Itinerary.transitions(out)
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].day, d(2026, 9, 11), "the 11th is the day you move")
        XCTAssertEqual(moves[0].from.place, "Bali")
        XCTAssertEqual(moves[0].to.place, "Singapore")
    }

    func testTripBoundsSpanBothStays() {
        let out = Itinerary.resolveOverlaps([
            Span(place: "Bali", start: d(2026, 9, 3), end: d(2026, 9, 12)),
            Span(place: "Singapore", start: d(2026, 9, 11), end: d(2026, 9, 14)),
        ], calendar: cal)
        let b = try! XCTUnwrap(Itinerary.bounds(out))
        XCTAssertEqual(b.start, d(2026, 9, 3))
        XCTAssertEqual(b.end, d(2026, 9, 14), "one trip, 3–14 Sep")
    }

    // MARK: The days in between

    func test10SeptemberIsAQuietBaliDay() {
        let out = Itinerary.resolveOverlaps([
            Span(place: "Bali", start: d(2026, 9, 3), end: d(2026, 9, 12)),
            Span(place: "Singapore", start: d(2026, 9, 11), end: d(2026, 9, 14)),
        ], calendar: cal)
        let tenth = d(2026, 9, 10)
        XCTAssertTrue(out[0].start <= tenth && tenth <= out[0].end, "the 10th is still Bali")
        XCTAssertFalse(Itinerary.transitions(out).contains { $0.day == tenth },
                       "nothing to catch on the 10th")
    }

    // MARK: Edge cases the resolver must not mangle

    func testAStaySwallowedEntirelyIsDropped() {
        // A one-day event inside a longer one that starts later: the shorter
        // earlier stay has nowhere left to live.
        let out = Itinerary.resolveOverlaps([
            Span(place: "Layover", start: d(2026, 9, 11), end: d(2026, 9, 11)),
            Span(place: "Singapore", start: d(2026, 9, 11), end: d(2026, 9, 14)),
        ], calendar: cal)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].place, "Singapore")
    }

    func testBackToBackStaysAreLeftAlone() {
        let out = Itinerary.resolveOverlaps([
            Span(place: "Bali", start: d(2026, 9, 3), end: d(2026, 9, 10)),
            Span(place: "Singapore", start: d(2026, 9, 11), end: d(2026, 9, 14)),
        ], calendar: cal)
        XCTAssertEqual(out[0].end, d(2026, 9, 10), "already tidy — nothing trimmed")
        XCTAssertEqual(Itinerary.transitions(out).count, 1)
    }

    func testThreeStaysChainCorrectly() {
        let out = Itinerary.resolveOverlaps([
            Span(place: "Bali", start: d(2026, 9, 3), end: d(2026, 9, 12)),
            Span(place: "Singapore", start: d(2026, 9, 11), end: d(2026, 9, 16)),
            Span(place: "Bangkok", start: d(2026, 9, 14), end: d(2026, 9, 18)),
        ], calendar: cal)
        XCTAssertEqual(out.map(\.end), [d(2026, 9, 10), d(2026, 9, 13), d(2026, 9, 18)])
        XCTAssertEqual(Itinerary.transitions(out).map(\.day), [d(2026, 9, 11), d(2026, 9, 14)])
    }

    func testSingleStayHasNoTransitions() {
        let out = Itinerary.resolveOverlaps([
            Span(place: "Bhadra", start: d(2026, 8, 15), end: d(2026, 8, 17)),
        ], calendar: cal)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(Itinerary.transitions(out).isEmpty)
    }

    func testEmptyInput() {
        XCTAssertTrue(Itinerary.resolveOverlaps([], calendar: cal).isEmpty)
        XCTAssertNil(Itinerary.bounds([]))
    }

    // MARK: Span carried on the event itself

    func testCalendarEventSpanDaysCountsInclusively() {
        let e = CalendarEvent(title: "Bali", startMinute: 0, endMinute: 0, location: "Bali",
                              isAllDay: true, externalID: "abc",
                              startDay: d(2026, 9, 3), endDay: d(2026, 9, 12))
        XCTAssertEqual(e.spanDays, 10, "3–12 Sep inclusive is 10 days")
    }

    func testEventWithoutASpanIsOneDay() {
        let e = CalendarEvent(title: "Dentist", startMinute: 600, endMinute: 660,
                              location: "", isAllDay: false)
        XCTAssertEqual(e.spanDays, 1)
    }
}
