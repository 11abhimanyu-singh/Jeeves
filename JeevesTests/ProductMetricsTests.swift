//
//  ProductMetricsTests.swift
//  JeevesTests
//
//  The three production metrics, pinned by definition. Each metric's meaning
//  is a product decision — these tests are where that decision lives, so it
//  can't drift silently while the number keeps being reported.
//

import XCTest
@testable import Jeeves

final class ProductMetricsTests: XCTestCase {

    private func at(_ h: Int, _ m: Int = 0, day: Int = 1) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: day,
                                                   hour: h, minute: m))!
    }

    private func call(_ name: String, _ h: Int, _ m: Int = 0, day: Int = 1,
                      subject: String = "") -> ProductMetrics.ToolCallRecord {
        .init(date: at(h, m, day: day), toolName: name, subject: subject)
    }

    // MARK: Correction rate

    func testCleanRunHasNoCorrections() {
        let calls = [call("add_trip", 9), call("add_journey", 9, 5), call("add_journey", 9, 10)]
        let m = ProductMetrics.correctionRate(calls)
        XCTAssertEqual(m.value, 0)
        XCTAssertEqual(m.sampleSize, 3)
    }

    func testEditsAndDeletesCountAsCorrections() throws {
        let calls = [call("add_event", 9), call("edit_event", 9, 20), call("delete_event", 9, 30)]
        let m = ProductMetrics.correctionRate(calls)
        XCTAssertEqual(try XCTUnwrap(m.value), 2.0 / 3.0, accuracy: 0.001)
    }

    func testRepeatingTheSameCreateOnTheSameSubjectIsACorrection() throws {
        // The fossil pattern: iterating by re-creating instead of amending.
        let calls = [call("add_journey", 9, subject: "trip-1"),
                     call("add_journey", 9, 10, subject: "trip-1"),
                     call("add_journey", 9, 20, subject: "trip-1")]
        let m = ProductMetrics.correctionRate(calls)
        XCTAssertEqual(try XCTUnwrap(m.value), 2.0 / 3.0, accuracy: 0.001,
                       "the two repeats are corrections; the first isn't")
    }

    func testSameToolOnDifferentSubjectsIsNotACorrection() {
        let calls = [call("add_journey", 9, subject: "trip-1"),
                     call("add_journey", 9, 10, subject: "trip-2")]
        XCTAssertEqual(ProductMetrics.correctionRate(calls).value, 0)
    }

    func testRepeatOutsideTheWindowIsNotACorrection() {
        let calls = [call("add_journey", 9, subject: "trip-1"),
                     call("add_journey", 14, subject: "trip-1")]
        XCTAssertEqual(ProductMetrics.correctionRate(calls).value, 0,
                       "five hours later is a new intent, not a fix")
    }

    func testReadOnlyToolsAreNotCounted() {
        let calls = [call("fetch_app_data", 9), call("commute_estimate", 9, 5),
                     call("add_todo", 9, 10)]
        let m = ProductMetrics.correctionRate(calls)
        XCTAssertEqual(m.sampleSize, 1, "only the mutating call is in the denominator")
    }

    func testNoDataIsHonestRatherThanZero() {
        let m = ProductMetrics.correctionRate([])
        XCTAssertNil(m.value)
        XCTAssertFalse(m.isConfident)
    }

    // MARK: Replan acceptance

    func testDaysThatKeptTheirFirstPlanCountAsAccepted() throws {
        let gens = [
            ProductMetrics.GenerationRecord(startedAt: at(8, day: 1), succeeded: true, isUserRequested: true),
            ProductMetrics.GenerationRecord(startedAt: at(8, day: 2), succeeded: true, isUserRequested: true),
            // Day 3 was replanned — not accepted.
            ProductMetrics.GenerationRecord(startedAt: at(8, day: 3), succeeded: true, isUserRequested: true),
            ProductMetrics.GenerationRecord(startedAt: at(19, day: 3), succeeded: true, isUserRequested: true),
        ]
        let m = ProductMetrics.replanAcceptance(gens)
        XCTAssertEqual(try XCTUnwrap(m.value), 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(m.sampleSize, 3, "three planned days")
    }

    func testOvernightAutoPlannerRunsAreExcluded() {
        // The auto-planner fills several days in one night; counting those as
        // replans of that night would make acceptance look terrible forever.
        let gens = [
            ProductMetrics.GenerationRecord(startedAt: at(4, 30, day: 1), succeeded: true, isUserRequested: false),
            ProductMetrics.GenerationRecord(startedAt: at(4, 31, day: 1), succeeded: true, isUserRequested: false),
            ProductMetrics.GenerationRecord(startedAt: at(9, day: 1), succeeded: true, isUserRequested: true),
        ]
        let m = ProductMetrics.replanAcceptance(gens)
        XCTAssertEqual(m.value, 1.0)
        XCTAssertEqual(m.sampleSize, 1)
    }

    func testFailedGenerationsDoNotCountAsPlannedDays() {
        let gens = [ProductMetrics.GenerationRecord(startedAt: at(9, day: 1), succeeded: false, isUserRequested: true)]
        XCTAssertNil(ProductMetrics.replanAcceptance(gens).value)
    }

    // MARK: Time to outcome

    func testMedianSpansFirstAskToLastChange() throws {
        let turns = [
            ProductMetrics.SessionTurn(date: at(9, 0), isUser: true),
            ProductMetrics.SessionTurn(date: at(9, 2), isUser: false),
            ProductMetrics.SessionTurn(date: at(9, 8), isUser: true),
            ProductMetrics.SessionTurn(date: at(9, 10), isUser: false),
        ]
        let calls = [call("add_trip", 9, 4), call("add_journey", 9, 9)]
        let m = ProductMetrics.timeToOutcome(turns: turns, calls: calls)
        XCTAssertEqual(try XCTUnwrap(m.value), 9, accuracy: 0.01, "09:00 first ask → 09:09 last change")
        XCTAssertEqual(m.sampleSize, 1)
    }

    func testSessionsSplitOnTheGap() throws {
        let turns = [
            ProductMetrics.SessionTurn(date: at(9, 0), isUser: true),
            ProductMetrics.SessionTurn(date: at(9, 5), isUser: false),
            // Two hours later — a different session.
            ProductMetrics.SessionTurn(date: at(11, 0), isUser: true),
            ProductMetrics.SessionTurn(date: at(11, 30), isUser: false),
        ]
        let calls = [call("add_todo", 9, 4), call("add_todo", 11, 20)]
        let m = ProductMetrics.timeToOutcome(turns: turns, calls: calls)
        XCTAssertEqual(m.sampleSize, 2)
        XCTAssertEqual(try XCTUnwrap(m.value), 12, accuracy: 0.01, "median of 4 and 20 minutes")
    }

    func testQuestionOnlySessionsAreExcluded() {
        let turns = [
            ProductMetrics.SessionTurn(date: at(9, 0), isUser: true),
            ProductMetrics.SessionTurn(date: at(9, 1), isUser: false),
        ]
        let m = ProductMetrics.timeToOutcome(turns: turns, calls: [])
        XCTAssertNil(m.value, "asking a question isn't an outcome")
    }

    // MARK: Honesty about small samples

    func testSmallSamplesAreNotClaimedAsTrends() {
        let calls = [call("add_todo", 9), call("delete_todo", 9, 5)]
        let m = ProductMetrics.correctionRate(calls)
        XCTAssertNotNil(m.value)
        XCTAssertFalse(m.isConfident, "two data points is not a trend")
        XCTAssertTrue(m.note.contains("too few"))
    }
}
