//
//  PlanDiagnosticsTests.swift
//  JeevesTests
//
//  The outcome classification and summary aggregation are pure, so they're
//  unit-testable without a store.
//

import XCTest
@testable import Jeeves

final class PlanDiagnosticsTests: XCTestCase {

    func testOutcomeClassification() {
        XCTAssertEqual(PlanDiagnostics.outcome(isOffline: true, retryCount: 0), .offlineFallback)
        XCTAssertEqual(PlanDiagnostics.outcome(isOffline: false, retryCount: 0), .success)
        XCTAssertEqual(PlanDiagnostics.outcome(isOffline: false, retryCount: 1), .repaired)
        XCTAssertEqual(PlanDiagnostics.outcome(isOffline: true, retryCount: 1), .offlineFallback,
                       "offline dominates — no Claude plan was returned")
    }

    private func log(_ outcome: PlanGenOutcome, _ ms: Int) -> PlanGenerationLog {
        let l = PlanGenerationLog(startedAt: .distantPast, trigger: .planner)
        l.outcome = outcome; l.durationMs = ms
        return l
    }

    func testSummaryCountsAndRate() {
        let logs = [log(.success, 1000), log(.repaired, 2000), log(.offlineFallback, 500),
                    log(.abandoned, 0), log(.pending, 0)]
        let s = PlanDiagnostics.summarize(logs)
        XCTAssertEqual(s.total, 4, "pending is in-flight and excluded from totals")
        XCTAssertEqual(s.succeeded, 2, "success + repaired")
        XCTAssertEqual(s.offline, 1)
        XCTAssertEqual(s.abandoned, 1)
        XCTAssertEqual(s.successRate, 0.5, accuracy: 0.0001)
    }

    func testSummaryPercentilesExcludeAbandoned() {
        let logs = [log(.success, 1000), log(.success, 2000), log(.success, 3000), log(.abandoned, 0)]
        let s = PlanDiagnostics.summarize(logs)
        XCTAssertGreaterThan(s.p50Ms, 0, "abandoned (0ms) must not drag the median to zero")
        XCTAssertLessThanOrEqual(s.p50Ms, 3000)
    }

    func testEmptySummaryIsZero() {
        let s = PlanDiagnostics.summarize([])
        XCTAssertEqual(s.total, 0)
        XCTAssertEqual(s.successRate, 0)
    }
}
