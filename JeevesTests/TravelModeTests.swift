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
        // Steps read CHRONOLOGICALLY — leave first, departure last — so the
        // card is a morning checklist, not a derivation.
        let plan = LeaveBy.forFlight(departAt: at(2026, 9, 4, 9, 40), checkInMinutes: 180,
                                     securityMinutes: 30, travelMinutes: 60, bufferMinutes: 20)
        XCTAssertEqual(plan.leaveAt, at(2026, 9, 4, 4, 50), "leave home at 04:50")
        XCTAssertEqual(plan.steps.count, 4)
        XCTAssertTrue(plan.steps.first?.isLeave == true, "the checklist starts with LEAVE")
        XCTAssertEqual(plan.steps[1].time, at(2026, 9, 4, 6, 10), "then be at the terminal")
        XCTAssertEqual(plan.steps[2].time, at(2026, 9, 4, 6, 40), "then the cut-off")
        XCTAssertEqual(plan.steps.last?.time, at(2026, 9, 4, 9, 40), "departure closes the chain")
        XCTAssertEqual(plan.steps.map(\.time), plan.steps.map(\.time).sorted(),
                       "strictly chronological")
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
        XCTAssertTrue(plan.steps.first?.isLeave == true, "chronological: LEAVE opens the chain")
        XCTAssertEqual(plan.steps[1].time, at(2026, 8, 15, 12, 40), "planned arrival keeps the contingency")
        XCTAssertEqual(plan.steps.last?.time, at(2026, 8, 15, 13, 0), "the deadline is last")
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
        // Same-day journeys keep their day: the leave-by moment falls on the
        // same date as the departure/deadline.
        let flight = TravelSegment(tripID: UUID(), mode: .flight, label: "6E 1605",
                                   departAt: at(2026, 9, 4, 9, 40))
        XCTAssertEqual(flight.day, cal.startOfDay(for: at(2026, 9, 4, 9, 40)))
        let drive = TravelSegment(tripID: UUID(), mode: .drive, label: "Drive",
                                  arriveBy: at(2026, 8, 15, 13, 0))
        XCTAssertEqual(drive.day, cal.startOfDay(for: at(2026, 8, 15, 13, 0)))
    }

    // MARK: Journey prefill — the hotel-as-flight-destination bug shipped
    // twice (outbound Kathmandu, then mirrored on the return leg), so the
    // rule is pinned: a flight's To is ALWAYS empty; only drives get places.

    func testReturnFlightNeverPrefillsADestination() {
        let p = JourneyPrefill.places(mode: .flight, isReturn: true, home: "12 Home Rd, Bengaluru",
                                      lastStay: "Hotel, Thimphu", firstStay: "Hotel, Thimphu",
                                      priorStay: nil)
        XCTAssertEqual(p.from, "Hotel, Thimphu", "the return leg leaves the last stay")
        XCTAssertEqual(p.to, "", "no stored place can know the departure airport — never Home")
    }

    func testReturnDriveHeadsHome() {
        let p = JourneyPrefill.places(mode: .drive, isReturn: true, home: "12 Home Rd, Bengaluru",
                                      lastStay: "Hotel, Thimphu", firstStay: "Hotel, Thimphu",
                                      priorStay: nil)
        XCTAssertEqual(p.from, "Hotel, Thimphu")
        XCTAssertEqual(p.to, "12 Home Rd, Bengaluru")
    }

    func testOutboundFlightNeverPrefillsADestination() {
        let p = JourneyPrefill.places(mode: .flight, isReturn: false, home: "12 Home Rd, Bengaluru",
                                      lastStay: "Hotel, Kathmandu", firstStay: "Hotel, Kathmandu",
                                      priorStay: nil)
        XCTAssertEqual(p.from, "12 Home Rd, Bengaluru", "outbound sets off from Home")
        XCTAssertEqual(p.to, "", "a flight's To stays empty — the Kathmandu 40-hour-road-route lesson")
    }

    func testOutboundDriveHeadsToTheFirstStay() {
        let p = JourneyPrefill.places(mode: .drive, isReturn: false, home: "12 Home Rd, Bengaluru",
                                      lastStay: "JLR River Tern Lodge", firstStay: "JLR River Tern Lodge",
                                      priorStay: nil)
        XCTAssertEqual(p.from, "12 Home Rd, Bengaluru")
        XCTAssertEqual(p.to, "JLR River Tern Lodge")
    }

    func testOutboundLeavesFromAPriorTripsStayWhenOneChains() {
        let p = JourneyPrefill.places(mode: .drive, isReturn: false, home: "12 Home Rd, Bengaluru",
                                      lastStay: "Marina Bay, Singapore", firstStay: "Marina Bay, Singapore",
                                      priorStay: "Karma Kandara, Bali")
        XCTAssertEqual(p.from, "Karma Kandara, Bali", "back-to-back trips chain stay to stay")
    }

    func testLongDriveAnchorsToItsLeaveByDay() {
        // The Kathmandu return: must arrive home 14 Oct 20:00 after ~40 h of
        // driving plus stops. The journey belongs to the day you LEAVE (the
        // 12th) — anchored to arrival it fell outside the trip entirely and
        // the most time-critical day read as a rest day.
        let drive = TravelSegment(tripID: UUID(), mode: .drive, label: "Drive home",
                                  arriveBy: at(2026, 10, 14, 20, 0),
                                  stopMinutes: 600, travelMinutes: 2400)
        XCTAssertEqual(drive.day, cal.startOfDay(for: at(2026, 10, 12, 0, 0)))
        XCTAssertEqual(drive.arrivalDay, cal.startOfDay(for: at(2026, 10, 14, 0, 0)),
                       "arrivalDay brackets the far end for trip-extension checks")
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
