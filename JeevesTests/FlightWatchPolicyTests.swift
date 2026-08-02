//
//  FlightWatchPolicyTests.swift
//  JeevesTests
//
//  "Start 12h out, check hourly, stop when it leaves." Every part of that is
//  pinned here — including the stopping, which is the part a polling loop
//  usually gets wrong and which costs battery silently when it does.
//

import XCTest
@testable import Jeeves

final class FlightWatchPolicyTests: XCTestCase {

    /// SQ 511: 23:05 IST, 3 Sep 2026.
    private var scheduled: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return cal.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 23, minute: 5))!
    }

    private func report(delay: Int = 0, departed: Date? = nil, cancelled: Bool = false,
                        observedAt: Date) -> FlightStatusReport {
        FlightStatusReport(flightNumber: "SQ 511",
                           scheduledDeparture: scheduled,
                           estimatedDeparture: scheduled.addingTimeInterval(Double(delay) * 60),
                           scheduledArrival: nil, estimatedArrival: nil,
                           departureTerminal: nil, arrivalTerminal: nil,
                           isCancelled: cancelled, actualDeparture: departed,
                           observedAt: observedAt)
    }

    // MARK: The window

    func testWatchingOpensExactlyTwelveHoursBefore() {
        XCTAssertEqual(FlightWatchPolicy.windowOpens(before: scheduled),
                       scheduled.addingTimeInterval(-12 * 3600))
    }

    func testNothingIsWatchedSixWeeksOut() {
        let now = scheduled.addingTimeInterval(-40 * 24 * 3600)
        XCTAssertFalse(FlightWatchPolicy.shouldWatch(scheduledDeparture: scheduled,
                                                     lastReport: nil, now: now))
        XCTAssertFalse(FlightWatchPolicy.isDue(scheduledDeparture: scheduled,
                                               lastChecked: nil, now: now))
    }

    func testTheFirstCheckIsDueTheMomentTheWindowOpens() {
        let opens = FlightWatchPolicy.windowOpens(before: scheduled)
        XCTAssertEqual(FlightWatchPolicy.nextCheck(scheduledDeparture: scheduled,
                                                   lastChecked: nil,
                                                   now: opens.addingTimeInterval(-3600)),
                       opens, "not an hour into the window — at its start")
        XCTAssertTrue(FlightWatchPolicy.isDue(scheduledDeparture: scheduled,
                                              lastChecked: nil, now: opens))
    }

    // MARK: Cadence

    func testHourlyThroughMostOfTheWindow() {
        let now = scheduled.addingTimeInterval(-10 * 3600)
        let last = now.addingTimeInterval(-30 * 60)
        XCTAssertFalse(FlightWatchPolicy.isDue(scheduledDeparture: scheduled,
                                               lastChecked: last, now: now),
                       "30 minutes after a check is not due")
        let hourAgo = now.addingTimeInterval(-61 * 60)
        XCTAssertTrue(FlightWatchPolicy.isDue(scheduledDeparture: scheduled,
                                              lastChecked: hourAgo, now: now))
    }

    func testItTightensInTheFinalApproach() {
        // Inside 2h of departure a delay matters more per minute.
        let close = scheduled.addingTimeInterval(-90 * 60)
        XCTAssertEqual(FlightWatchPolicy.cadenceMinutes(scheduledDeparture: scheduled, at: close), 20)
        let farther = scheduled.addingTimeInterval(-8 * 3600)
        XCTAssertEqual(FlightWatchPolicy.cadenceMinutes(scheduledDeparture: scheduled, at: farther), 60)
    }

    // MARK: Stopping — the part that costs battery when it's wrong

    func testADepartedFlightIsNeverCheckedAgain() {
        let now = scheduled.addingTimeInterval(10 * 60)
        let gone = report(departed: scheduled.addingTimeInterval(5 * 60), observedAt: now)
        XCTAssertFalse(FlightWatchPolicy.shouldWatch(scheduledDeparture: scheduled,
                                                     lastReport: gone, now: now))
        XCTAssertNil(FlightWatchPolicy.nextCheck(scheduledDeparture: scheduled,
                                                 lastChecked: now, lastReport: gone, now: now))
    }

    func testACancelledFlightIsNeverCheckedAgain() {
        let now = scheduled.addingTimeInterval(-5 * 3600)
        let dead = report(cancelled: true, observedAt: now)
        XCTAssertFalse(FlightWatchPolicy.shouldWatch(scheduledDeparture: scheduled,
                                                     lastReport: dead, now: now))
    }

    func testItGivesUpWhenTheProviderNeverReportsADeparture() {
        // Otherwise a flight that simply stops being reported is polled forever.
        let now = scheduled.addingTimeInterval(7 * 3600)
        XCTAssertFalse(FlightWatchPolicy.shouldWatch(scheduledDeparture: scheduled,
                                                     lastReport: nil, now: now))
    }

    func testADelayedButAirborneFlightStillStops() {
        let now = scheduled.addingTimeInterval(4 * 3600)
        let gone = report(delay: 180, departed: scheduled.addingTimeInterval(180 * 60), observedAt: now)
        XCTAssertFalse(FlightWatchPolicy.shouldWatch(scheduledDeparture: scheduled,
                                                     lastReport: gone, now: now))
    }

    // MARK: Scheduling one wake-up for a whole trip

    func testTheEarliestLegDecidesWhenToWake() {
        let now = scheduled.addingTimeInterval(-20 * 3600)
        let second = scheduled.addingTimeInterval(30 * 3600)
        let next = FlightWatchPolicy.earliestNextCheck(
            departures: [(scheduled, nil), (second, nil)], now: now)
        XCTAssertEqual(next, FlightWatchPolicy.windowOpens(before: scheduled),
                       "the sooner leg opens first")
    }

    func testNoWakeUpWhenNothingIsLeftToWatch() {
        let now = scheduled.addingTimeInterval(48 * 3600)
        XCTAssertNil(FlightWatchPolicy.earliestNextCheck(departures: [(scheduled, now)], now: now))
    }

    // MARK: The cache

    func testAReportRoundTripsAndKeepsItsDepartureFlag() {
        let key = "SQ TEST"
        let now = Date()
        var r = report(delay: 45, observedAt: now)
        r.flightNumber = key
        FlightStatusStore.save(r, checkedAt: now)
        defer { FlightStatusStore.prune(now: now.addingTimeInterval(40 * 24 * 3600)) }

        let back = FlightStatusStore.report(flightNumber: key, scheduledDeparture: scheduled)
        XCTAssertEqual(back?.delayMinutes, 45)
        XCTAssertEqual(back?.hasDeparted, false)
        XCTAssertNotNil(FlightStatusStore.lastChecked(flightNumber: key, scheduledDeparture: scheduled))
    }

    func testTheSameFlightNumberOnDifferentDaysIsNotConfused() {
        // SQ 511 flies daily. Keying on the number alone would have yesterday's
        // status answering for today's flight.
        let a = FlightStatusStore.identity(flightNumber: "SQ 511", scheduledDeparture: scheduled)
        let b = FlightStatusStore.identity(flightNumber: "SQ 511",
                                           scheduledDeparture: scheduled.addingTimeInterval(24 * 3600))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, FlightStatusStore.identity(flightNumber: "SQ511",
                                                      scheduledDeparture: scheduled),
                       "spacing in a flight number must not split the key")
    }

    func testPruningDropsFlightsLongGone() {
        let old = Date().addingTimeInterval(-30 * 24 * 3600)
        var r = report(observedAt: old)
        r.flightNumber = "OLD 1"
        r.scheduledDeparture = old
        FlightStatusStore.save(r, checkedAt: old)
        FlightStatusStore.prune()
        XCTAssertNil(FlightStatusStore.report(flightNumber: "OLD 1", scheduledDeparture: old))
    }

    // MARK: Departure reaches the state machine

    func testADepartedFlightShowsAsDepartedNotOnTime() {
        let now = scheduled.addingTimeInterval(20 * 60)
        let gone = report(departed: scheduled.addingTimeInterval(3 * 60), observedAt: now)
        let state = FlightWatch.state(report: gone, scheduledDeparture: scheduled, now: now)
        guard case .departed = state else { return XCTFail("got \(state)") }
        XCTAssertFalse(state.isActionable, "there is nothing left to decide")
    }
}
