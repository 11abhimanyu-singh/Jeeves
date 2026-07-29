//
//  TravelDetectionTests.swift
//  JeevesTests
//
//  Telling a travel day from an ordinary day with an appointment on it. The
//  cases are the user's own: a one-hour consultation twenty minutes away on
//  19 Aug must NEVER prompt, while the three-day Bhadra tour and a six-hour
//  drive must. Getting this wrong in the permissive direction costs a tap;
//  getting it wrong the other way wastes a morning.
//

import XCTest
@testable import Jeeves

final class TravelDetectionTests: XCTestCase {

    private var cal: Calendar { Calendar(identifier: .gregorian) }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private typealias C = TravelDetection.Candidate

    // MARK: Ordinary days must stay ordinary

    func testShortAppointmentNearbyIsNotTravel() {
        // 19 Aug: Silent Monkee consultation, 1 hour, ~20 minutes away.
        let c = C(title: "Silent Monkee: In-person Consultation", day: day(2026, 8, 19),
                  isAllDay: false, hasLocation: true, eventMinutes: 60, journeyMinutes: 20)
        XCTAssertNil(TravelDetection.suggestion(for: [c], calendar: cal))
    }

    func testLongEventNearbyIsNotTravel() {
        // A four-hour workshop across town is a long day, not a trip.
        let c = C(title: "Workshop", day: day(2026, 8, 19), isAllDay: false,
                  hasLocation: true, eventMinutes: 240, journeyMinutes: 40)
        XCTAssertNil(TravelDetection.suggestion(for: [c], calendar: cal))
    }

    func testUnmeasuredJourneyIsNeverAssumedFar() {
        // No journey time means we don't know — and we don't guess.
        let c = C(title: "Somewhere", day: day(2026, 8, 19), isAllDay: false,
                  hasLocation: true, eventMinutes: 60, journeyMinutes: nil)
        XCTAssertNil(TravelDetection.suggestion(for: [c], calendar: cal))
    }

    func testAllDayWithoutLocationIsNotTravel() {
        // Diwali, a birthday, a public holiday — all-day, no place.
        let c = C(title: "Diwali", day: day(2026, 11, 8), isAllDay: true,
                  hasLocation: false, eventMinutes: 0, journeyMinutes: nil)
        XCTAssertNil(TravelDetection.suggestion(for: [c], calendar: cal))
    }

    func testEmptyDayIsNotTravel() {
        XCTAssertNil(TravelDetection.suggestion(for: [], calendar: cal))
    }

    // MARK: Travel days must be caught

    func testMultiDayEventWithLocationIsTravel() {
        // 15–17 Aug Bhadra: caught with NO journey measurement at all.
        let c = C(title: "Bhadra Tiger Reserve -Tour", day: day(2026, 8, 15), isAllDay: true,
                  hasLocation: true, eventMinutes: 0, journeyMinutes: nil, spanDays: 3)
        let s = try! XCTUnwrap(TravelDetection.suggestion(for: [c], calendar: cal))
        XCTAssertTrue(s.isStrong)
        XCTAssertEqual(s.startDay, day(2026, 8, 15))
        XCTAssertEqual(s.endDay, day(2026, 8, 17), "the whole span goes into travel mode")
    }

    func testLongJourneyIsTravel() {
        // Six hours each way to the lodge.
        let c = C(title: "JLR River Tern Lodge", day: day(2026, 8, 15), isAllDay: false,
                  hasLocation: true, eventMinutes: 60, journeyMinutes: 360)
        let s = try! XCTUnwrap(TravelDetection.suggestion(for: [c], calendar: cal))
        XCTAssertTrue(s.isStrong)
        XCTAssertTrue(s.reason.contains("6 h"), "the reason names the journey: \(s.reason)")
    }

    func testRoundTripThatEatsTheDayIsTravel() {
        // 3 h each way (under the one-way threshold) + a 5 h event = 11 h.
        let c = C(title: "Cousin's wedding", day: day(2026, 8, 22), isAllDay: false,
                  hasLocation: true, eventMinutes: 300, journeyMinutes: 180)
        let s = try! XCTUnwrap(TravelDetection.suggestion(for: [c], calendar: cal))
        XCTAssertTrue(s.isStrong)
    }

    func testJustUnderTheRoundTripThresholdStaysOrdinary() {
        // 2 h each way + a 2 h event = 6 h. A long day, not a trip.
        let c = C(title: "Client visit", day: day(2026, 8, 22), isAllDay: false,
                  hasLocation: true, eventMinutes: 120, journeyMinutes: 120)
        XCTAssertNil(TravelDetection.suggestion(for: [c], calendar: cal))
    }

    func testAllDayWithLocationIsAWeakSuggestion() {
        let c = C(title: "Bali", day: day(2026, 9, 4), isAllDay: true,
                  hasLocation: true, eventMinutes: 0, journeyMinutes: nil)
        let s = try! XCTUnwrap(TravelDetection.suggestion(for: [c], calendar: cal))
        XCTAssertFalse(s.isStrong, "a single all-day event is only a hint")
    }

    func testStrongSignalWinsOverWeakOne() {
        let weak = C(title: "Some marker", day: day(2026, 8, 15), isAllDay: true,
                     hasLocation: true, eventMinutes: 0, journeyMinutes: nil)
        let strong = C(title: "Bhadra", day: day(2026, 8, 15), isAllDay: true,
                       hasLocation: true, eventMinutes: 0, journeyMinutes: nil, spanDays: 3)
        let s = try! XCTUnwrap(TravelDetection.suggestion(for: [weak, strong], calendar: cal))
        XCTAssertEqual(s.title, "Bhadra", "the multi-day trip is the reason shown")
    }

    // MARK: Multi-day grouping

    func testConsecutiveDaysCountAsOneSpan() {
        let days = [day(2026, 8, 15), day(2026, 8, 16), day(2026, 8, 17)]
        XCTAssertEqual(TravelDetection.spanDays(title: "Bhadra", days: days, calendar: cal), 3)
    }

    func testNonConsecutiveDaysDoNotExtendTheSpan() {
        // A weekly recurring event isn't a trip.
        let days = [day(2026, 8, 15), day(2026, 8, 22), day(2026, 8, 29)]
        XCTAssertEqual(TravelDetection.spanDays(title: "Weekly", days: days, calendar: cal), 1)
    }

    func testDuplicateDaysDontInflateTheSpan() {
        let days = [day(2026, 8, 15), day(2026, 8, 15), day(2026, 8, 16)]
        XCTAssertEqual(TravelDetection.spanDays(title: "Dup", days: days, calendar: cal), 2)
    }
}
