//
//  FlightStatusTests.swift
//  JeevesTests
//
//  Two rules under test, both of them product decisions rather than mechanics:
//
//  1. Nothing moves a leave-by on its own. A delay produces a PROPOSAL.
//  2. Silence is never rendered as "on time".
//

import XCTest
@testable import Jeeves

final class FlightStatusTests: XCTestCase {

    /// SQ 511 as sold: 23:05 IST on 3 Sep 2026.
    private var scheduled: Date {
        var c = DateComponents(year: 2026, month: 9, day: 3, hour: 23, minute: 5)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return cal.date(from: c)!
    }

    private func report(delayMinutes: Int, observedMinutesAgo: Double = 2,
                        now: Date, cancelled: Bool = false) -> FlightStatusReport {
        FlightStatusReport(flightNumber: "SQ 511",
                           scheduledDeparture: scheduled,
                           estimatedDeparture: scheduled.addingTimeInterval(Double(delayMinutes) * 60),
                           scheduledArrival: nil, estimatedArrival: nil,
                           departureTerminal: "2", arrivalTerminal: "3",
                           isCancelled: cancelled,
                           observedAt: now.addingTimeInterval(-observedMinutesAgo * 60))
    }

    // MARK: The watch window

    func testFarFromDepartureItIsNotWatchingAndSaysSo() {
        let now = scheduled.addingTimeInterval(-40 * 24 * 3600)   // six weeks out
        let state = FlightWatch.state(report: nil, scheduledDeparture: scheduled, now: now)
        guard case .notYetWatching(let from) = state else {
            return XCTFail("expected notYetWatching, got \(state)")
        }
        XCTAssertEqual(from.timeIntervalSince(scheduled), -12 * 3600, accuracy: 1)
    }

    func testInsideTheWindowWithNoReadingIsStaleNotOnTime() {
        let now = scheduled.addingTimeInterval(-4 * 3600)
        let state = FlightWatch.state(report: nil, scheduledDeparture: scheduled, now: now)
        XCTAssertEqual(state, .stale(lastSuccess: nil),
                       "no data must never render as on time")
    }

    func testAnOldReadingGoesStaleRatherThanReportingOnTime() {
        let now = scheduled.addingTimeInterval(-3 * 3600)
        let old = report(delayMinutes: 0, observedMinutesAgo: 7 * 60, now: now)
        let state = FlightWatch.state(report: old, scheduledDeparture: scheduled, now: now)
        guard case .stale(let last) = state else {
            return XCTFail("a seven-hour-old check is not a current 'on time', got \(state)")
        }
        XCTAssertEqual(last, old.observedAt)
    }

    func testFreshAndOnSchedule() {
        let now = scheduled.addingTimeInterval(-3 * 3600)
        let state = FlightWatch.state(report: report(delayMinutes: 0, now: now),
                                      scheduledDeparture: scheduled, now: now)
        guard case .onTime = state else { return XCTFail("got \(state)") }
    }

    // MARK: Late

    func testALateFlightWithNoDecisionIsActionable() {
        let now = scheduled.addingTimeInterval(-9 * 3600)
        let state = FlightWatch.state(report: report(delayMinutes: 180, now: now),
                                      scheduledDeparture: scheduled, now: now)
        guard case .lateUndecided(let minutes, _) = state else { return XCTFail("got \(state)") }
        XCTAssertEqual(minutes, 180)
        XCTAssertTrue(state.isActionable, "an unresolved delay must keep asking")
    }

    func testOnceDecidedTheDelayStaysVisibleButStopsNagging() {
        let now = scheduled.addingTimeInterval(-9 * 3600)
        let decided = scheduled.addingTimeInterval(-2 * 3600)
        let state = FlightWatch.state(report: report(delayMinutes: 180, now: now),
                                      scheduledDeparture: scheduled,
                                      decision: .init(leaveBy: decided, forDelayMinutes: 180),
                                      now: now)
        guard case .lateSettled(let minutes, let leaveBy) = state else { return XCTFail("got \(state)") }
        XCTAssertEqual(minutes, 180)
        XCTAssertEqual(leaveBy, decided)
        XCTAssertFalse(state.isActionable)
    }

    func testCancellationOutranksEverything() {
        let now = scheduled.addingTimeInterval(-5 * 3600)
        let state = FlightWatch.state(report: report(delayMinutes: 30, now: now, cancelled: true),
                                      scheduledDeparture: scheduled, now: now)
        guard case .cancelled = state else { return XCTFail("got \(state)") }
        XCTAssertTrue(state.isActionable)
    }

    // MARK: The four ways .onTime used to be reachable by accident

    func testAFlightBroughtForwardIsNotOnTime() {
        // The dangerous direction: the flight moved EARLIER, so the existing
        // leave-by is now too late and you miss it. This reported .onTime.
        let now = scheduled.addingTimeInterval(-6 * 3600)
        let state = FlightWatch.state(report: report(delayMinutes: -40, now: now),
                                      scheduledDeparture: scheduled, now: now)
        guard case .lateUndecided(let minutes, _) = state else {
            return XCTFail("a flight brought forward needs the same decision as a delay, got \(state)")
        }
        XCTAssertEqual(minutes, -40)
        XCTAssertTrue(state.isActionable)
    }

    func testAFlightBroughtForwardStillGetsAProposal() {
        let now = scheduled.addingTimeInterval(-6 * 3600)
        let p = LeaveByRevision.propose(currentLeaveBy: scheduled.addingTimeInterval(-315 * 60),
                                        report: report(delayMinutes: -40, now: now),
                                        bufferMinutes: 240, journeyMinutes: 75,
                                        journeyRemeasured: true)
        XCTAssertEqual(p?.shiftMinutes, -40, "you must be told to leave EARLIER")
    }

    func testAReadingStampedInTheFutureIsStaleNotOnTime() {
        // Provider clock skew, or a zone bug parsing observedAt, slipped past
        // a one-sided freshness test and produced a green state.
        let now = scheduled.addingTimeInterval(-3 * 3600)
        let future = report(delayMinutes: 0, observedMinutesAgo: -10 * 24 * 60, now: now)
        let state = FlightWatch.state(report: future, scheduledDeparture: scheduled, now: now)
        guard case .stale = state else {
            return XCTFail("a reading from the future is not a current 'on time', got \(state)")
        }
    }

    func testACancellationIsShownDaysAheadNotHiddenByTheWatchWindow() {
        // Airlines cancel days out. Gating this behind the 12h window hid the
        // one fact worth knowing early for 36 hours.
        let now = scheduled.addingTimeInterval(-48 * 3600)
        let state = FlightWatch.state(report: report(delayMinutes: 0, now: now, cancelled: true),
                                      scheduledDeparture: scheduled, now: now)
        guard case .cancelled = state else { return XCTFail("got \(state)") }
        XCTAssertTrue(state.isActionable)
    }

    func testADecisionOnlySettlesTheDelayItWasMadeFor() {
        // Settle at 60 minutes, then the flight slips to 300. The old decision
        // must not keep a four-hour-wrong leave-by on screen with the row
        // silent.
        let now = scheduled.addingTimeInterval(-9 * 3600)
        let decided = scheduled.addingTimeInterval(-255 * 60)
        let state = FlightWatch.state(report: report(delayMinutes: 300, now: now),
                                      scheduledDeparture: scheduled,
                                      decision: .init(leaveBy: decided, forDelayMinutes: 60),
                                      now: now)
        guard case .lateUndecided(let minutes, _) = state else {
            return XCTFail("a decision must not cover a delay five times larger, got \(state)")
        }
        XCTAssertEqual(minutes, 300)
        XCTAssertTrue(state.isActionable)
    }

    func testASmallFurtherSlipDoesNotReopenASettledDecision() {
        // The other side: re-asking on every two-minute re-time would be noise.
        let now = scheduled.addingTimeInterval(-9 * 3600)
        let decided = scheduled.addingTimeInterval(-135 * 60)
        let state = FlightWatch.state(report: report(delayMinutes: 185, now: now),
                                      scheduledDeparture: scheduled,
                                      decision: .init(leaveBy: decided, forDelayMinutes: 180),
                                      now: now)
        guard case .lateSettled = state else { return XCTFail("got \(state)") }
    }

    func testACancelledFlightGetsNoLeaveByProposal() {
        let now = scheduled.addingTimeInterval(-5 * 3600)
        XCTAssertNil(LeaveByRevision.propose(currentLeaveBy: scheduled,
                                             report: report(delayMinutes: 180, now: now, cancelled: true),
                                             bufferMinutes: 240, journeyMinutes: 75,
                                             journeyRemeasured: true),
                     "proposing a leave-by for a journey that isn't happening is an assertion, not a help")
    }

    func testSmallDelaysAreShownButDoNotInterrupt() {
        XCTAssertFalse(FlightWatch.shouldNotify(delayMinutes: 5))
        XCTAssertFalse(FlightWatch.shouldNotify(delayMinutes: 19))
        XCTAssertTrue(FlightWatch.shouldNotify(delayMinutes: 20))
        XCTAssertTrue(FlightWatch.shouldNotify(delayMinutes: 180))
    }

    // MARK: The proposal — the part that must never apply itself

    func testADelayProducesAProposalAndChangesNothing() {
        let now = scheduled.addingTimeInterval(-9 * 3600)
        let currentLeaveBy = scheduled.addingTimeInterval(-(75 + 240) * 60)   // 17:50 IST
        let r = report(delayMinutes: 180, now: now)

        let proposal = LeaveByRevision.propose(currentLeaveBy: currentLeaveBy,
                                               report: r,
                                               bufferMinutes: 240,
                                               journeyMinutes: 75,
                                               journeyRemeasured: true)
        let p = try? XCTUnwrap(proposal)
        XCTAssertEqual(p?.delayMinutes, 180)
        XCTAssertEqual(p?.shiftMinutes, 180, "the proposal moves with the flight")
        XCTAssertEqual(p?.current, currentLeaveBy, "the CURRENT leave-by is untouched")
        XCTAssertEqual(p?.journeyRemeasured, true)
    }

    func testAShiftedEstimateIsMarkedAsNotRemeasured() {
        // Traffic at 20:50 is not traffic at 17:50. When the journey could not
        // be re-measured the proposal has to say so rather than wear a
        // measured face.
        let now = scheduled.addingTimeInterval(-9 * 3600)
        let p = LeaveByRevision.propose(currentLeaveBy: scheduled.addingTimeInterval(-315 * 60),
                                        report: report(delayMinutes: 180, now: now),
                                        bufferMinutes: 240,
                                        journeyMinutes: 75,
                                        journeyRemeasured: false)
        XCTAssertEqual(p?.journeyRemeasured, false)
    }

    func testNoProposalForAnOnTimeFlight() {
        let now = scheduled.addingTimeInterval(-9 * 3600)
        XCTAssertNil(LeaveByRevision.propose(currentLeaveBy: scheduled,
                                             report: report(delayMinutes: 0, now: now),
                                             bufferMinutes: 240,
                                             journeyMinutes: 75,
                                             journeyRemeasured: true))
    }

    func testKeepingTheOldLeaveByShowsTheRealCostOfDoingNothing() {
        let now = scheduled.addingTimeInterval(-9 * 3600)
        let currentLeaveBy = scheduled.addingTimeInterval(-315 * 60)   // 17:50
        let idle = LeaveByRevision.idleMinutesIfUnchanged(currentLeaveBy: currentLeaveBy,
                                                          journeyMinutes: 75,
                                                          report: report(delayMinutes: 180, now: now))
        // Arrive 19:05, flight now 02:05 → 7h 00m of waiting.
        XCTAssertEqual(idle, 420)
        XCTAssertEqual(TicketItinerary.durationLabel(idle), "7h 00m")
    }

    // MARK: The stand-in provider

    func testTheUnconfiguredProviderRefusesRatherThanInventing() async {
        let provider = UnconfiguredFlightStatusProvider()
        do {
            _ = try await provider.status(flightNumber: "SQ 511", departingOn: scheduled)
            XCTFail("a provider with no service behind it must not return a status")
        } catch {
            XCTAssertTrue(error is UnconfiguredFlightStatusProvider.NotConfigured)
        }
    }
}
