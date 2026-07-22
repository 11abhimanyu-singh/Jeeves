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
}
