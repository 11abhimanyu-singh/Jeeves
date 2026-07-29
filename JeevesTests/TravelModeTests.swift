//
//  TravelModeTests.swift
//  JeevesTests
//
//  The leave-by arithmetic. This is the number the user reads at 4am in an
//  unfamiliar airport, so every branch is pinned: flights work backwards
//  through the cut-off, security and traffic; drives work backwards through
//  the driving and any stops; and a trip's day range decides which days the
//  planner stands down on.
//

import XCTest
@testable import Jeeves

final class TravelModeTests: XCTestCase {

    private var cal: Calendar { Calendar(identifier: .gregorian) }
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: Flights

    func testFlightChainMatchesTheWorkedExample() {
        // 6E 1605 departs 09:40; 3 h cut-off, 30 m security, 60 m drive, 20 m buffer.
        let plan = LeaveBy.forFlight(departAt: at(2026, 9, 4, 9, 40), checkInMinutes: 180,
                                     securityMinutes: 30, travelMinutes: 60, bufferMinutes: 20)
        XCTAssertEqual(plan.leaveAt, at(2026, 9, 4, 4, 50), "leave home at 04:50")
        XCTAssertEqual(plan.steps.count, 5)
        XCTAssertEqual(plan.steps[1].time, at(2026, 9, 4, 6, 40), "cut-off 3 h before")
        XCTAssertEqual(plan.steps[2].time, at(2026, 9, 4, 6, 10), "at the terminal")
        XCTAssertTrue(plan.steps.last?.isLeave == true)
    }

    func testFlightChainCrossesMidnightBackwards() {
        // An 01:30 departure means leaving the previous evening — the chain
        // must not wrap into the same day.
        let plan = LeaveBy.forFlight(departAt: at(2026, 9, 5, 1, 30), checkInMinutes: 180,
                                     securityMinutes: 30, travelMinutes: 60, bufferMinutes: 20)
        XCTAssertEqual(plan.leaveAt, at(2026, 9, 4, 20, 40))
    }

    func testDomesticShorterCutoffLeavesLater() {
        let intl = LeaveBy.forFlight(departAt: at(2026, 9, 4, 9, 40), checkInMinutes: 180,
                                     securityMinutes: 30, travelMinutes: 60, bufferMinutes: 20)
        let dom = LeaveBy.forFlight(departAt: at(2026, 9, 4, 9, 40), checkInMinutes: 120,
                                    securityMinutes: 30, travelMinutes: 60, bufferMinutes: 20)
        XCTAssertEqual(dom.leaveAt.timeIntervalSince(intl.leaveAt), 3600,
                       "an hour less cut-off = leave an hour later")
    }

    // MARK: Drives

    func testDriveChainWithStops() {
        // Bhadra: must arrive 13:00, 6 h driving, 55 m of stops, 20 m contingency.
        let plan = LeaveBy.forDrive(arriveBy: at(2026, 8, 15, 13, 0), travelMinutes: 360,
                                    stopMinutes: 55, bufferMinutes: 20)
        XCTAssertEqual(plan.leaveAt, at(2026, 8, 15, 5, 45), "leave home at 05:45")
        XCTAssertEqual(plan.steps.first?.time, at(2026, 8, 15, 13, 0))
        XCTAssertEqual(plan.steps[1].time, at(2026, 8, 15, 12, 40), "planned arrival keeps the contingency")
    }

    func testStopsPushTheDepartureEarlier() {
        let without = LeaveBy.forDrive(arriveBy: at(2026, 8, 15, 13, 0), travelMinutes: 360,
                                       stopMinutes: 0, bufferMinutes: 20)
        let with = LeaveBy.forDrive(arriveBy: at(2026, 8, 15, 13, 0), travelMinutes: 360,
                                    stopMinutes: 55, bufferMinutes: 20)
        XCTAssertEqual(without.leaveAt.timeIntervalSince(with.leaveAt), 55 * 60,
                       "55 minutes of stops = leave 55 minutes earlier")
    }

    // MARK: Segment dispatch

    func testSegmentWithoutItsTimeHasNoPlan() {
        let flight = TravelSegment(tripID: UUID(), mode: .flight, label: "6E 1605")
        XCTAssertNil(LeaveBy.plan(for: flight), "a flight with no departure can't be planned")
        let drive = TravelSegment(tripID: UUID(), mode: .drive, label: "Drive")
        XCTAssertNil(LeaveBy.plan(for: drive), "a drive with no arrival deadline can't be planned")
    }

    func testSegmentDayIsTheJourneysDay() {
        let flight = TravelSegment(tripID: UUID(), mode: .flight, label: "6E 1605",
                                   departAt: at(2026, 9, 4, 9, 40))
        XCTAssertEqual(flight.day, cal.startOfDay(for: at(2026, 9, 4, 9, 40)))
        let drive = TravelSegment(tripID: UUID(), mode: .drive, label: "Drive",
                                  arriveBy: at(2026, 8, 15, 13, 0))
        XCTAssertEqual(drive.day, cal.startOfDay(for: at(2026, 8, 15, 13, 0)))
    }

    // MARK: Which days go into travel mode

    func testTripCoversItsWholeRangeInclusive() {
        let trip = Trip(title: "Bali", startDate: at(2026, 9, 4, 12), endDate: at(2026, 9, 14, 12))
        XCTAssertTrue(trip.covers(at(2026, 9, 4, 23), calendar: cal), "first day counts")
        XCTAssertTrue(trip.covers(at(2026, 9, 9, 3), calendar: cal), "middle days count")
        XCTAssertTrue(trip.covers(at(2026, 9, 14, 1), calendar: cal), "last day counts")
        XCTAssertFalse(trip.covers(at(2026, 9, 3, 23), calendar: cal), "the day before does not")
        XCTAssertFalse(trip.covers(at(2026, 9, 15, 0), calendar: cal), "the day after does not")
        XCTAssertEqual(trip.dayCount, 11)
    }

    func testSingleDayTripIsValid() {
        let trip = Trip(title: "Bhadra", startDate: at(2026, 8, 15, 9), endDate: at(2026, 8, 15, 9))
        XCTAssertTrue(trip.covers(at(2026, 8, 15, 18), calendar: cal))
        XCTAssertEqual(trip.dayCount, 1)
    }

    func testHoursFormatting() {
        XCTAssertEqual(LeaveBy.hours(45), "45 min")
        XCTAssertEqual(LeaveBy.hours(120), "2 h")
        XCTAssertEqual(LeaveBy.hours(360), "6 h")
        XCTAssertEqual(LeaveBy.hours(95), "1 h 35 min")
    }
}
