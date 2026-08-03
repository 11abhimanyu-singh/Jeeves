//
//  AdherenceStatsTests.swift
//  JeevesTests
//
//  One rule under test above all others: the rate never hides its
//  denominator. Blocks nobody asked about sit OUTSIDE the fraction.
//

import XCTest
@testable import Jeeves

final class AdherenceStatsTests: XCTestCase {

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date())!.startOfDay
    }
    private func session(_ title: String, planned: Int, actual: Int,
                         state: ActivityState = .done, unit: ActivityUnit? = .questions,
                         quantity: Int? = nil) -> ActivitySession {
        let start = Date().addingTimeInterval(-Double(actual) * 60)
        let s = ActivitySession(day: Date(), blockKey: title, title: title,
                                plannedMinutes: planned, unit: unit, startedAt: start)
        s.endedAt = start.addingTimeInterval(Double(actual) * 60)
        s.state = state
        if let quantity { s.record(quantity: quantity) }
        return s
    }

    // MARK: the denominator

    func testUnknownsAreExcludedFromTheRateAndReportedSeparately() {
        let stats = AdherenceStats.build(
            days: [(day(0), [.done, .done, .done, .skipped, .unknown, .unknown], false)],
            sessions: [], routine: [])
        XCTAssertEqual(stats.done, 3)
        XCTAssertEqual(stats.skipped, 1)
        XCTAssertEqual(stats.unknown, 2)
        XCTAssertEqual(stats.assessable, 4, "the two nobody asked about are not in the fraction")
        XCTAssertEqual(stats.rate ?? 0, 0.75, accuracy: 0.001)
    }

    /// Rolling unknowns in as misses would turn a week where the chain stalled
    /// into a week that looks like slacking — and the planner would then shrink
    /// the very blocks that did get done.
    func testFoldingUnknownsInWouldChangeTheAnswer() {
        let stats = AdherenceStats.build(
            days: [(day(0), [.done, .unknown, .unknown, .unknown], false)],
            sessions: [], routine: [])
        XCTAssertEqual(stats.rate ?? 0, 1.0, accuracy: 0.001,
                       "one assessable block, and it was done")
        XCTAssertEqual(stats.unknown, 3)
    }

    func testNothingAssessableGivesNoRateRatherThanZero() {
        let stats = AdherenceStats.build(days: [(day(0), [.unknown], false)],
                                         sessions: [], routine: [])
        XCTAssertNil(stats.rate, "0% would read as total failure; there is simply no answer")
    }

    func testTravelDaysAreMarkedAndCarryNoBlocks() {
        let stats = AdherenceStats.build(days: [(day(0), [], true)], sessions: [], routine: [])
        XCTAssertTrue(stats.days.first?.isTravel ?? false)
        XCTAssertEqual(stats.days.first?.assessable, 0)
    }

    // MARK: drift

    func testDriftUsesTheMedianSoOneLongAfternoonCannotRewriteARoutine() {
        let sessions = [
            session("Interview prep — Product Sense", planned: 45, actual: 50),
            session("Interview prep — Product Sense", planned: 45, actual: 55),
            session("Interview prep — Product Sense", planned: 45, actual: 240),
        ]
        let stats = AdherenceStats.build(days: [], sessions: sessions, routine: [])
        let drift = stats.drifts.first
        XCTAssertEqual(drift?.medianActualMinutes, 55, "median, not mean")
        XCTAssertEqual(drift?.sessions, 3)
        XCTAssertTrue(drift?.isConfident ?? false)
    }

    func testTwoSessionsIsNotYetAPattern() {
        let sessions = [
            session("Reading habit", planned: 60, actual: 70, unit: .pages),
            session("Reading habit", planned: 60, actual: 75, unit: .pages),
        ]
        let stats = AdherenceStats.build(days: [], sessions: sessions, routine: [])
        XCTAssertFalse(stats.drifts.first?.isConfident ?? true,
                       "a bad afternoon is not a trend — no retiming offer yet")
    }

    /// An auto-closed session knows when it started and nothing else.
    /// Averaging it in would teach the planner a number nobody measured.
    func testAutoClosedSessionsAreExcludedFromDrift() {
        let sessions = [
            session("Interview prep — Strategy", planned: 30, actual: 35),
            session("Interview prep — Strategy", planned: 30, actual: 600, state: .needsDetail),
        ]
        let stats = AdherenceStats.build(days: [], sessions: sessions, routine: [])
        XCTAssertEqual(stats.drifts.first?.sessions, 1)
        XCTAssertEqual(stats.drifts.first?.medianActualMinutes, 35)
    }

    func testDriftPrefersTheRoutinesOwnDurationAsThePlan() {
        let routine = [RoutineActivity(name: "Product Sense", durationMinutes: 30,
                                       tier: .important, sortOrder: 0,
                                       group: .interviewPrep, prepCategory: .productSense)]
        let stats = AdherenceStats.build(
            days: [],
            sessions: [session("Interview prep — Product Sense", planned: 45, actual: 50)],
            routine: routine)
        XCTAssertEqual(stats.drifts.first?.plannedMinutes, 30,
                       "the routine is the source of truth for what was planned")
        XCTAssertEqual(stats.drifts.first?.driftMinutes, 20)
    }

    // MARK: totals and gaps

    func testTotalsCountOnlyWhatWasActuallyGiven() {
        let sessions = [
            session("Interview prep — Execution", planned: 30, actual: 30, quantity: 5),
            session("Interview prep — Strategy", planned: 30, actual: 30, quantity: 3),
            session("Interview prep — Behavioral", planned: 30, actual: 30),   // no count
        ]
        let stats = AdherenceStats.build(days: [], sessions: sessions, routine: [])
        XCTAssertEqual(stats.totals.first { $0.unit == .questions }?.count, 8,
                       "silence is not a zero")
    }

    func testGapsNameEveryReasonThePictureIsIncomplete() {
        let sessions = [
            session("Interview prep — Execution", planned: 30, actual: 999, state: .needsDetail),
            session("Interview prep — Strategy", planned: 30, actual: 30),      // logged, no count
        ]
        let stats = AdherenceStats.build(days: [(day(0), [.unknown, .unknown], false)],
                                         sessions: sessions, routine: [])
        let reasons = stats.gaps.map(\.reason)
        XCTAssertTrue(reasons.contains { $0.contains("never asked") })
        XCTAssertTrue(reasons.contains { $0.contains("duration unknown") })
        XCTAssertTrue(reasons.contains { $0.contains("no count given") })
        XCTAssertEqual(stats.gaps.first { $0.reason.contains("never asked") }?.count, 2)
    }

    func testACleanWeekHasNoGapsPanel() {
        let stats = AdherenceStats.build(
            days: [(day(0), [.done, .done], false)],
            sessions: [session("Interview prep — Execution", planned: 30, actual: 30, quantity: 4)],
            routine: [])
        XCTAssertTrue(stats.gaps.isEmpty)
    }
}
