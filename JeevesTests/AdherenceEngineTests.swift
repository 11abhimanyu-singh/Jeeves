//
//  AdherenceEngineTests.swift
//  JeevesTests
//
//  The inference + scoring is pure, so it's fully unit-testable: cross-
//  referencing a plan against the day's logs to decide what was followed,
//  what was skipped, and what can't be judged.
//

import XCTest
@testable import Jeeves

final class AdherenceEngineTests: XCTestCase {

    private func b(_ title: String, kind: String = "activity") -> GeneratedBlock {
        GeneratedBlock(title: title, startTime: "08:00", endTime: "09:00", note: nil, isAnchor: false, kind: kind)
    }

    private func plan(_ blocks: [GeneratedBlock]) -> GeneratedPlan {
        GeneratedPlan(blocks: blocks, dropped: [], shrunk: [], summary: "", boundaryTime: nil)
    }

    func testReadingDoneWhenReadToday() {
        let p = plan([b("Interview prep — Reading"), b("Reading habit")])
        var e = DayEvidence(); e.readToday = true
        XCTAssertEqual(AdherenceEngine.infer(plan: p, evidence: e), [.done, .done])
    }

    func testReadingSkippedWhenNoReadingLog() {
        let p = plan([b("Reading habit")])
        XCTAssertEqual(AdherenceEngine.infer(plan: p, evidence: DayEvidence()), [.skipped])
    }

    func testGymDoneWhenWorkedOut() {
        let p = plan([b("Weightlifting", kind: "gym"), b("Cardio", kind: "gym")])
        var e = DayEvidence(); e.workedOut = true
        XCTAssertEqual(AdherenceEngine.infer(plan: p, evidence: e), [.done, .done])
    }

    func testJobApplicationsTrackFromLog() {
        let p = plan([b("Job applications")])
        var e = DayEvidence(); e.appliedToJobs = true
        XCTAssertEqual(AdherenceEngine.infer(plan: p, evidence: e), [.done])
        XCTAssertEqual(AdherenceEngine.infer(plan: p, evidence: DayEvidence()), [.skipped])
    }

    func testUnloggableBlocksAreUnknown() {
        let p = plan([b("Lunch", kind: "lunch"), b("Commute home", kind: "commute"),
                      b("Sleep", kind: "sleep"), b("Chores"), b("Free time", kind: "free")])
        XCTAssertEqual(AdherenceEngine.infer(plan: p, evidence: DayEvidence()),
                       [.unknown, .unknown, .unknown, .unknown, .unknown])
    }

    func testScoreIgnoresUnknownsAndReflectsCompletion() {
        // 2 done, 1 skipped, 2 unknown → 2/3 assessable.
        let outcomes: [BlockOutcome] = [.done, .done, .skipped, .unknown, .unknown]
        XCTAssertEqual(AdherenceEngine.score(outcomes)!, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(AdherenceEngine.assessableCount(outcomes), 3)
    }

    func testScoreNilWhenNothingAssessable() {
        XCTAssertNil(AdherenceEngine.score([.unknown, .unknown]),
                     "an unlogged day is not a zero-adherence day")
    }

    func testPhotographyTracksLeisureLog() {
        let p = plan([b("Photography")])
        var e = DayEvidence(); e.leisureLogged = [.photography]
        XCTAssertEqual(AdherenceEngine.infer(plan: p, evidence: e), [.done])
    }

    // MARK: Manual overrides

    func testManualMarkWinsOverInferred() {
        let p = plan([b("Reading habit"), b("Photography")])
        let inferred: [BlockOutcome] = [.skipped, .done]
        let manual = [AdherenceEngine.key(p.blocks[0]): BlockOutcome.done]  // "actually I did read"
        let eff = AdherenceEngine.effective(plan: p, inferred: inferred, manual: manual)
        XCTAssertEqual(eff, [.done, .done])
    }

    func testKeyIsStablePerBlock() {
        let block = b("Lunch", kind: "lunch")
        XCTAssertEqual(AdherenceEngine.key(block), "08:00|Lunch")
    }

    // MARK: Tier-weighted score

    private var routine: [BaselineActivity] { Baseline.activities }

    func testWeightedScorePenalizesMissedMustDoMore() {
        // Lunch (Must-do=3) missed, Photography (Flexible=1) done → 1 / (3+1) =
        // 0.25, much lower than equal-weight 0.5.
        let p = plan([b("Lunch", kind: "lunch"), b("Photography")])
        let outcomes: [BlockOutcome] = [.skipped, .done]
        let w = AdherenceEngine.weightedScore(plan: p, outcomes: outcomes, routine: routine)!
        XCTAssertEqual(w, 0.25, accuracy: 0.0001)
        XCTAssertEqual(AdherenceEngine.score(outcomes)!, 0.5, accuracy: 0.0001)
    }

    func testWeightedScoreRewardsKeepingTheMustDo() {
        // Must-do done, Flexible skipped → 3 / (3+1) = 0.75.
        let p = plan([b("Lunch", kind: "lunch"), b("Photography")])
        let w = AdherenceEngine.weightedScore(plan: p, outcomes: [.done, .skipped], routine: routine)!
        XCTAssertEqual(w, 0.75, accuracy: 0.0001)
    }

    func testReadingIsImportantWeightNotMustDo() {
        // Reading is now Important (weight 2): missed reading + done flexible →
        // 1 / (2+1) = 0.333, not the 0.25 a Must-do would give.
        let p = plan([b("Interview prep — Reading"), b("Photography")])
        let w = AdherenceEngine.weightedScore(plan: p, outcomes: [.skipped, .done], routine: routine)!
        XCTAssertEqual(w, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testWeightedScoreNilWhenNothingAssessable() {
        let p = plan([b("Lunch", kind: "lunch")])
        XCTAssertNil(AdherenceEngine.weightedScore(plan: p, outcomes: [.unknown], routine: routine))
    }
}
