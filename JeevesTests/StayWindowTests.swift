//
//  StayWindowTests.swift
//  JeevesTests
//
//  Hotel policy arithmetic. Scenario 9 of the permanent test plan turns on
//  this: "checkout before 11:30, check-in after 2 pm, breakfast 7:30-10:30 —
//  work the drives around that." Before this existed a transition drive aimed
//  at a hardcoded noon, which is after most checkouts AND before most
//  check-ins, so it was wrong at both ends.
//

import XCTest
@testable import Jeeves

final class StayWindowTests: XCTestCase {

    // MARK: The comfortable case

    func testLongDriveLandsAfterCheckInWithNoWait() {
        // Wayanad → Ooty, ~3h: leave at the 11:30 checkout, arrive 14:30.
        let t = StayWindow.transition(travelMinutes: 180)
        XCTAssertEqual(t.leaveMinute, 11 * 60 + 30)
        XCTAssertEqual(t.arriveMinute, 14 * 60 + 30)
        XCTAssertEqual(t.waitMinutes, 0)
        XCTAssertNil(t.caveat, "both windows satisfied — nothing to warn about")
        XCTAssertEqual(t.arriveByMinute, t.arriveMinute)
    }

    func testArrivingExactlyAtCheckInCountsAsNoWait() {
        // 11:30 + 2h30 = 14:00 on the nose.
        let t = StayWindow.transition(travelMinutes: 150)
        XCTAssertEqual(t.waitMinutes, 0)
        XCTAssertNil(t.caveat)
    }

    // MARK: The case that must be said out loud

    func testShortDriveArrivesBeforeCheckInAndSaysSo() {
        // A 1h hop: leaving at checkout lands 12:30, 90 min early.
        let t = StayWindow.transition(travelMinutes: 60)
        XCTAssertEqual(t.arriveMinute, 12 * 60 + 30)
        XCTAssertEqual(t.waitMinutes, 90)
        XCTAssertEqual(t.arriveByMinute, 14 * 60,
                       "the deadline is check-in, not the early arrival")
        let caveat = try? XCTUnwrap(t.caveat)
        XCTAssertNotNil(caveat)
        XCTAssertTrue(t.caveat?.contains("11:30") ?? false, "names the checkout it used")
        XCTAssertTrue(t.caveat?.contains("14:00") ?? false, "names the check-in it missed")
        XCTAssertTrue(t.caveat?.contains("1h 30m") ?? false, "quantifies the wait")
    }

    // MARK: Custom policies

    func testCustomWindowsAreRespected() {
        // A resort with a late 15:00 check-in and an early 10:00 checkout.
        let t = StayWindow.transition(checkoutMinute: 10 * 60,
                                      checkinMinute: 15 * 60,
                                      travelMinutes: 120)
        XCTAssertEqual(t.leaveMinute, 10 * 60)
        XCTAssertEqual(t.arriveMinute, 12 * 60)
        XCTAssertEqual(t.waitMinutes, 180)
        XCTAssertNotNil(t.caveat)
    }

    func testZeroAndNegativeTravelAreHandled() {
        let zero = StayWindow.transition(travelMinutes: 0)
        XCTAssertEqual(zero.arriveMinute, zero.leaveMinute)
        let negative = StayWindow.transition(travelMinutes: -30)
        XCTAssertEqual(negative.arriveMinute, negative.leaveMinute,
                       "a negative measurement can't move the clock backwards")
    }

    // MARK: Breakfast is a preference, not a constraint

    func testLeavingBeforeBreakfastEndsProducesANote() {
        let note = StayWindow.breakfastNote(leaveMinute: 9 * 60, breakfastEnds: 10 * 60 + 30)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("10:30") ?? false)
    }

    func testLeavingAfterBreakfastIsSilent() {
        XCTAssertNil(StayWindow.breakfastNote(leaveMinute: 11 * 60 + 30,
                                              breakfastEnds: 10 * 60 + 30),
                     "the default 11:30 checkout is after breakfast — no note needed")
    }

    // MARK: Formatting

    func testClockAndDurationFormatting() {
        XCTAssertEqual(StayWindow.clock(14 * 60), "14:00")
        XCTAssertEqual(StayWindow.clock(11 * 60 + 30), "11:30")
        XCTAssertEqual(StayWindow.hhmm(45), "45m")
        XCTAssertEqual(StayWindow.hhmm(120), "2h")
        XCTAssertEqual(StayWindow.hhmm(150), "2h 30m")
    }

    func testDefaultsAreTheCommonHotelWindows() {
        XCTAssertEqual(StayWindow.defaultCheckin, 14 * 60)
        XCTAssertEqual(StayWindow.defaultCheckout, 11 * 60 + 30)
    }
}
