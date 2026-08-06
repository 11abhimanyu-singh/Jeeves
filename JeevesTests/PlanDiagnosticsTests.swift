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

    func testSummaryBreaksDownClaudeVsCommute() {
        func spanned(_ total: Int, claude: Int, commute: Int) -> PlanGenerationLog {
            let l = PlanGenerationLog(startedAt: .distantPast, trigger: .planner)
            l.outcome = .success; l.durationMs = total; l.claudeMs = claude; l.commuteMs = commute
            return l
        }
        // Claude dominates; commute is small — the breakdown should show it.
        let s = PlanDiagnostics.summarize([
            spanned(38000, claude: 35000, commute: 3000),
            spanned(40000, claude: 37000, commute: 3000),
            spanned(34000, claude: 31000, commute: 3000),
        ])
        XCTAssertEqual(s.p50ClaudeMs, 35000)
        XCTAssertEqual(s.p50CommuteMs, 3000)
        XCTAssertGreaterThan(s.p50ClaudeMs, s.p50CommuteMs, "Claude is the bottleneck, not the Maps lookups")
    }
}

/// Which rule the model broke, reduced to something countable.
///
/// Up to 45% of chat generations made TWO full ~53s calls because the first
/// plan failed validation. The repair rate was visible; which rule caused it
/// was not — so the largest slice of planner latency was unfixable.
final class ViolationClassTests: XCTestCase {

    func testAMessageBecomesItsKind() {
        XCTAssertEqual(PlanDiagnostics.violationKinds(
            ["'Lunch' starts 14:45, past the 14:30 deadline"]), "lunch-window")
        XCTAssertEqual(PlanDiagnostics.violationKinds(
            ["'Reading' 09:00–10:00 overlaps 'Chores' 09:30–10:10"]), "overlap")
        XCTAssertEqual(PlanDiagnostics.violationKinds(
            ["'Interview prep — Strategy' and 'Interview prep — Execution' have 0 min between them; interview-prep blocks need 10"]),
            "prep-breather")
    }

    /// The point is a TALLY, so the same rule broken three times is one kind,
    /// and the order can't depend on which violation happened to come first.
    func testKindsAreDedupedAndStable() {
        let messages = [
            "'A' overlaps 'B'",
            "'C' overlaps 'D'",
            "'Lunch' starts 14:45, past the 14:30 deadline",
        ]
        XCTAssertEqual(PlanDiagnostics.violationKinds(messages), "lunch-window,overlap")
        XCTAssertEqual(PlanDiagnostics.violationKinds(messages.reversed()),
                       PlanDiagnostics.violationKinds(messages),
                       "a tally must not depend on violation order")
    }

    /// Every gym message PlanValidation emits, VERBATIM. The classifier keys on
    /// wording, so rewording a rule can silently retire its bucket: when the
    /// length rule became "Gym is N min…" the tally kept reporting gym-shape from
    /// the other two rules while its most common member counted as "other".
    /// If a gym message is reworded again, this fails instead of going quiet.
    func testEveryGymMessageClassifiesAsGymShape() {
        let emitted = [
            "Gym day but no gym block in the plan",
            "Gym is 60 min — the session is 90 min and must never be compressed",
            "Gym is 120 min — the session is 90 min",
            "Gym routine is split: \"Cardio\" starts at 07:40 but \"Weightlifting\" ends at 07:10 — mobility, weightlifting, cardio must run back-to-back",
        ]
        for message in emitted {
            XCTAssertEqual(PlanDiagnostics.violationKinds([message]), "gym-shape",
                           "this is a gym violation and must be tallied as one: \(message)")
        }
    }

    /// An unrecognised message still counts as something — a rule that stops
    /// being matched would otherwise vanish from the tally silently.
    func testAnUnknownMessageIsStillCounted() {
        XCTAssertEqual(PlanDiagnostics.violationKinds(["something nobody anticipated"]), "other")
    }

    func testNoViolationsRecordsNothing() {
        XCTAssertEqual(PlanDiagnostics.violationKinds([]), "")
    }
}
