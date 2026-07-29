//
//  TravelClockTests.swift
//  JeevesTests
//
//  Crossing timezones. The failure this prevents is concrete: a flight leaving
//  Singapore at 19:40 SGT, entered while the user is still in Bengaluru, must
//  not be stored as 19:40 IST — that's 2½ hours wrong, and on a leave-by time
//  it's a missed flight.
//

import XCTest
@testable import Jeeves

final class TravelClockTests: XCTestCase {

    private let ist = TimeZone(identifier: "Asia/Kolkata")!      // UTC+5:30
    private let sgt = TimeZone(identifier: "Asia/Singapore")!    // UTC+8
    private let wita = TimeZone(identifier: "Asia/Makassar")!    // UTC+8
    private let nyc = TimeZone(identifier: "America/New_York")!  // UTC-4/-5

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    private func wall(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, in tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: Reading a wall-clock in another zone

    func testTimeEnteredForAnotherZoneIsStoredAsTheRightInstant() {
        // The user is in India; the picker hands back "19:40" in IST. The flight
        // leaves Singapore, so those digits must be read on SGT.
        let typed = wall(2026, 9, 14, 19, 40, in: ist)
        let instant = TravelClock.instant(readingWallClock: typed, in: sgt, deviceZone: ist)
        XCTAssertEqual(instant, utc(2026, 9, 14, 11, 40), "19:40 SGT is 11:40 UTC")
        XCTAssertEqual(TravelClock.hhmm(instant, in: sgt), "19:40")
        XCTAssertEqual(TravelClock.hhmm(instant, in: ist), "17:10", "the same moment reads 17:10 back home")
    }

    func testRoundTripThroughTheEditorDoesNotDrift() {
        // Open a saved segment, don't touch it, save again — the instant must
        // survive unchanged.
        let original = utc(2026, 9, 14, 11, 40)
        let shown = TravelClock.wallClock(of: original, in: sgt, deviceZone: ist)
        let resaved = TravelClock.instant(readingWallClock: shown, in: sgt, deviceZone: ist)
        XCTAssertEqual(resaved, original)
    }

    func testSameZoneIsANoOp() {
        let typed = wall(2026, 8, 15, 5, 45, in: ist)
        XCTAssertEqual(TravelClock.instant(readingWallClock: typed, in: ist, deviceZone: ist), typed)
    }

    // MARK: Labels and offsets

    func testOffsetBetweenZones() {
        let at = utc(2026, 9, 4, 4, 10)
        XCTAssertEqual(TravelClock.offsetLabel(from: ist, to: wita, at: at), "+2 h 30 min")
        XCTAssertEqual(TravelClock.offsetLabel(from: wita, to: ist, at: at), "\u{2212}2 h 30 min")
        XCTAssertNil(TravelClock.offsetLabel(from: sgt, to: wita, at: at),
                     "Singapore and Bali share a clock — nothing to say")
    }

    // MARK: Overnight flights

    func testFlightLandingNextDayIsFlagged() {
        // Departs 22:10 SGT on the 14th, lands 01:30 IST on the 15th.
        let dep = wall(2026, 9, 14, 22, 10, in: sgt)
        let arr = wall(2026, 9, 15, 1, 30, in: ist)
        XCTAssertTrue(TravelClock.crossesDay(departure: dep, departureZone: sgt,
                                             arrival: arr, arrivalZone: ist))
    }

    func testSameDayFlightIsNotFlagged() {
        let dep = wall(2026, 9, 4, 9, 40, in: ist)
        let arr = wall(2026, 9, 4, 17, 5, in: wita)
        XCTAssertFalse(TravelClock.crossesDay(departure: dep, departureZone: ist,
                                              arrival: arr, arrivalZone: wita))
    }

    func testWestwardFlightCanLandBeforeItLeftOnTheClock() {
        // Bengaluru → New York: departs 02:00 IST, lands 08:30 the SAME date in
        // New York despite 16 hours in the air. Different calendar days.
        let dep = wall(2026, 9, 4, 2, 0, in: ist)
        let arr = wall(2026, 9, 3, 22, 30, in: nyc)
        XCTAssertTrue(TravelClock.crossesDay(departure: dep, departureZone: ist,
                                             arrival: arr, arrivalZone: nyc))
        XCTAssertLessThan(dep, arr, "the instant still moves forward even if the clock reads earlier")
    }

    // MARK: A segment's day is reckoned where it starts

    func testSegmentDayUsesTheOriginZone() {
        // 00:30 departure from Singapore belongs to that Singapore day — back
        // home it's still the previous evening.
        let dep = wall(2026, 9, 15, 0, 30, in: sgt)
        let s = TravelSegment(tripID: UUID(), mode: .flight, label: "6E 1606",
                              departAt: dep, fromTimeZoneID: "Asia/Singapore")
        var sgCal = Calendar(identifier: .gregorian); sgCal.timeZone = sgt
        XCTAssertEqual(s.day, sgCal.startOfDay(for: dep))
    }

    // MARK: The leave-by chain is zone-agnostic

    func testLeaveByArithmeticIsUnaffectedByZones() {
        // The chain works on instants, so the same flight yields the same
        // leave-by moment however it's labelled — only the display changes.
        let dep = wall(2026, 9, 14, 19, 40, in: sgt)
        // 19:40 − 3 h cut-off − 25 m security − 20 m ride − 20 m buffer = 15:35.
        let plan = LeaveBy.forFlight(departAt: dep, checkInMinutes: 180, securityMinutes: 25,
                                     travelMinutes: 20, bufferMinutes: 20)
        XCTAssertEqual(TravelClock.hhmm(plan.leaveAt, in: sgt), "15:35", "leave the hotel at 15:35 SGT")
        XCTAssertEqual(TravelClock.hhmm(plan.leaveAt, in: ist), "13:05", "the same moment back home")
    }
}
