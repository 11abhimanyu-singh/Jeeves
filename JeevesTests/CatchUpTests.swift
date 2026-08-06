//
//  CatchUpTests.swift
//  JeevesTests
//
//  What the prompt asks about, and — more importantly — what it doesn't.
//  A prompt that re-asks settled questions gets dismissed on sight, and then
//  the backfill window it exists to serve goes unused anyway.
//

import XCTest
@testable import Jeeves

final class CatchUpTests: XCTestCase {

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date())!.startOfDay
    }
    private func block(_ title: String, _ start: String = "14:00", _ end: String = "14:45") -> GeneratedBlock {
        GeneratedBlock(title: title, startTime: start, endTime: end,
                       note: nil, isAnchor: false, kind: "activity")
    }
    private func plan(_ blocks: [GeneratedBlock]) -> GeneratedPlan {
        GeneratedPlan(blocks: blocks, dropped: [], shrunk: [], summary: "", boundaryTime: nil)
    }
    private func session(_ key: String, day: Date, state: ActivityState) -> ActivitySession {
        let s = ActivitySession(day: day, blockKey: key, title: key,
                                plannedMinutes: 45, unit: .questions, startedAt: day)
        s.state = state
        return s
    }

    // MARK: what it asks

    func testWithheldBlocksAreAskedAbout() {
        let b = block("Interview prep — Execution")
        let key = AdherenceEngine.key(b)
        let out = CatchUp.pending(
            days: [(day(-1), plan([b]), [key], [], [])], sessions: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.reason, .neverAsked)
        XCTAssertEqual(out.first?.plannedMinutes, 45)
    }

    func testAutoClosedSessionsAreAskedAbout() {
        let out = CatchUp.pending(
            days: [(day(-1), nil, [], [], [])],
            sessions: [session("k", day: day(-1), state: .needsDetail)])
        XCTAssertEqual(out.first?.reason, .closedItself)
    }

    // MARK: what it leaves alone

    func testASettledSkipIsNotReAsked() {
        let b = block("Interview prep — Execution")
        // Not withheld: the nudge fired, and the answer was no.
        let out = CatchUp.pending(days: [(day(-1), plan([b]), [], [], [])], sessions: [])
        XCTAssertTrue(out.isEmpty, "an answer is not a question")
    }

    func testAlreadyLoggedBlocksAreNotReAsked() {
        let b = block("Interview prep — Execution")
        let key = AdherenceEngine.key(b)
        let out = CatchUp.pending(days: [(day(-1), plan([b]), [key], [key], [])], sessions: [])
        XCTAssertTrue(out.isEmpty)
    }

    func testUnmeasurableBlocksAreNeverAskedAbout() {
        let b = block("Commute Home → Gym")
        let key = AdherenceEngine.key(b)
        let out = CatchUp.pending(days: [(day(-1), plan([b]), [key], [], [])], sessions: [])
        XCTAssertTrue(out.isEmpty, "there was never anything to count")
    }

    func testOutsideTheWindowIsSealed() {
        let b = block("Interview prep — Execution")
        let key = AdherenceEngine.key(b)
        let out = CatchUp.pending(days: [(day(-3), plan([b]), [key], [], [])], sessions: [])
        XCTAssertTrue(out.isEmpty, "editable until the end of the next day, then sealed")
    }

    func testABlockIsAskedAboutOnceEvenIfBothReasonsApply() {
        let b = block("Interview prep — Execution")
        let key = AdherenceEngine.key(b)
        let out = CatchUp.pending(
            days: [(day(-1), plan([b]), [key], [], [])],
            sessions: [session(key, day: day(-1), state: .needsDetail)])
        XCTAssertEqual(out.count, 1, "one row per block, not one per reason")
    }

    // MARK: work that didn't happen
    //
    // "Collect spectacles" was scheduled and skipped on the 4th AND the 5th.
    // Marking it skipped wrote one JSON entry and that was the end of it —
    // nothing carried it forward, nothing asked, it simply left the plan.

    func testSkippedWorkOnAPastDayIsOfferedARescue() {
        let b = block("Collect spectacles")
        let key = AdherenceEngine.key(b)
        let out = CatchUp.pending(days: [(day(-1), plan([b]), [], [], [key])], sessions: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.reason, .leftUndone)
        XCTAssertTrue(out.first?.reason.wantsRescue ?? false,
                      "the question is what happens next, not whether it happened")
    }

    /// A block skipped this morning may still happen this evening. Asking at
    /// lunchtime is the app nagging, not helping.
    func testSkippedWorkOnTODAYIsLeftAlone() {
        let b = block("Collect spectacles")
        let key = AdherenceEngine.key(b)
        let out = CatchUp.pending(days: [(day(0), plan([b]), [], [], [key])], sessions: [])
        XCTAssertTrue(out.isEmpty, "the day is not over yet")
    }

    func testAnAlreadyLoggedSkipIsNotDraggedBack() {
        let b = block("Collect spectacles")
        let key = AdherenceEngine.key(b)
        let out = CatchUp.pending(days: [(day(-1), plan([b]), [], [key], [key])], sessions: [])
        XCTAssertTrue(out.isEmpty, "it was done after all — nothing to rescue")
    }

    /// A block can be withheld AND later marked skipped. "What now?" outranks
    /// "did you?", because the second question already has its answer.
    func testRescueOutranksTheUnansweredQuestion() {
        let b = block("Interview prep — Execution")
        let key = AdherenceEngine.key(b)
        let out = CatchUp.pending(days: [(day(-1), plan([b]), [key], [], [key])], sessions: [])
        XCTAssertEqual(out.count, 1, "one row per block, not one per reason")
        XCTAssertEqual(out.first?.reason, .leftUndone)
    }

    // MARK: asking once a day

    func testItAsksOncePerDay() {
        let defaults = UserDefaults(suiteName: "catchup.test")!
        defaults.removePersistentDomain(forName: "catchup.test")
        let now = Date()

        XCTAssertTrue(CatchUp.shouldAsk(now: now, defaults: defaults), "never asked yet")
        CatchUp.markAsked(now: now, defaults: defaults)
        XCTAssertFalse(CatchUp.shouldAsk(now: now, defaults: defaults), "already asked today")

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        XCTAssertTrue(CatchUp.shouldAsk(now: tomorrow, defaults: defaults), "a new day, a new ask")
    }

    func testResultsAreOrderedByDayThenTitle() {
        let a = block("Interview prep — Strategy")
        let b = block("Interview prep — Behavioral")
        let out = CatchUp.pending(
            days: [(day(0), plan([a, b]), [AdherenceEngine.key(a), AdherenceEngine.key(b)], [], [])],
            sessions: [])
        XCTAssertEqual(out.map(\.title), ["Interview prep — Behavioral", "Interview prep — Strategy"])
    }
}
