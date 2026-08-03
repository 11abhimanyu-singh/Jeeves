//
//  ActivitySessionTests.swift
//  JeevesTests
//
//  Sessions, and the evidence they leave behind.
//
//  The second half matters most: PrepSession is written NOWHERE in this app,
//  which is why every interview-prep block has been crossed since 20 July and
//  why the planner is handed "most neglected: Product Sense" every morning by
//  a ranking computed over an empty table. These tests pin the first writer.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class ActivitySessionTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() {
        super.setUp()
        let schema = Schema([ActivitySession.self, PrepSession.self, JobApplication.self,
                             LeisureLog.self, ReadingLog.self, AppEvent.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try! ModelContainer(for: schema, configurations: [config])
    }
    override func tearDown() { container = nil; super.tearDown() }

    private func prep() -> [PrepSession] { (try? context.fetch(FetchDescriptor<PrepSession>())) ?? [] }

    // MARK: elapsed time

    func testPausedTimeIsNotCounted() {
        let t0 = Date()
        let s = ActivitySession(day: t0, blockKey: "k", title: "Interview prep — Product Sense",
                                plannedMinutes: 45, unit: .questions, startedAt: t0)
        s.pause(at: t0.addingTimeInterval(600))          // ran 10 min
        XCTAssertEqual(s.elapsed(asOf: t0.addingTimeInterval(1200)), 600, accuracy: 1,
                       "the clock is frozen while paused")
        s.resume(at: t0.addingTimeInterval(1200))        // paused 10 min
        s.stop(at: t0.addingTimeInterval(1800))          // ran 10 more
        XCTAssertEqual(s.elapsed(), 1200, accuracy: 1, "20 min of work, 10 of pause")
        XCTAssertEqual(s.actualMinutes, 20)
        XCTAssertEqual(s.driftMinutes, -25, "45 planned, 20 done")
    }

    func testStoppingWhilePausedStillBanksThePause() {
        let t0 = Date()
        let s = ActivitySession(day: t0, blockKey: "k", title: "Reading habit",
                                plannedMinutes: 60, unit: .pages, startedAt: t0)
        s.pause(at: t0.addingTimeInterval(300))
        s.stop(at: t0.addingTimeInterval(900))
        XCTAssertEqual(s.actualMinutes, 5, "the ten minutes spent paused are not work")
    }

    /// An auto-closed session knows when it started and nothing else. Reporting
    /// a duration for it would be inventing the exact kind of number the
    /// planner later learns from.
    func testAutoClosedSessionsReportNoDrift() {
        let t0 = Date()
        let s = ActivitySession(day: t0, blockKey: "k", title: "Interview prep — Execution",
                                plannedMinutes: 45, unit: .questions, startedAt: t0)
        s.autoClose(at: t0.addingTimeInterval(9999))
        XCTAssertEqual(s.state, .needsDetail)
        XCTAssertNil(s.driftMinutes)
    }

    func testAQuantityOfZeroIsNotTheSameAsSilence() {
        let s = ActivitySession(day: Date(), blockKey: "k", title: "Reading habit",
                                plannedMinutes: 60, unit: .pages)
        XCTAssertFalse(s.quantityGiven, "nobody has been asked yet")
        s.record(quantity: 0)
        XCTAssertTrue(s.quantityGiven, "'I read nothing' is an answer")
    }

    // MARK: one clock

    func testStartingASecondBlockFinishesTheFirst() {
        let day = Date()
        let a = ActivityTracker.start(blockKey: "a", title: "Interview prep — Strategy",
                                      plannedMinutes: 30, day: day, context: context)
        let b = ActivityTracker.start(blockKey: "b", title: "Reading habit",
                                      plannedMinutes: 60, day: day, context: context)
        XCTAssertNotNil(b)
        XCTAssertFalse(a?.isLive ?? true, "two clocks can't run at once")
        XCTAssertEqual(ActivitySession.live(in: context)?.blockKey, "b")
    }

    func testStartingTheSameBlockTwiceReopensIt() {
        let day = Date()
        let a = ActivityTracker.start(blockKey: "a", title: "Interview prep — Strategy",
                                      plannedMinutes: 30, day: day, context: context)
        ActivityTracker.finish(a!, quantity: 3, context: context)
        let again = ActivityTracker.start(blockKey: "a", title: "Interview prep — Strategy",
                                          plannedMinutes: 30, day: day, context: context)
        XCTAssertEqual(ActivitySession.onDay(day, in: context).count, 1,
                       "one record per block per day, not a second attempt")
        XCTAssertTrue(again?.isLive ?? false)
    }

    func testUnmeasurableBlocksNeverStart() {
        let day = Date()
        for title in ["Commute Home → Gym", "Lunch", "Chores", "Free time", "Sleep", "Gym"] {
            XCTAssertNil(ActivityTracker.start(blockKey: title, title: title,
                                               plannedMinutes: 30, day: day, context: context),
                         "\(title) has nothing to count")
        }
    }

    // MARK: evidence — the reason this feature exists

    func testFinishingAPracticeBlockWritesThePrepSessionThatNothingElseWrites() {
        let day = Date()
        XCTAssertTrue(prep().isEmpty)
        let s = ActivityTracker.start(blockKey: "ps", title: "Interview prep — Product Sense",
                                      plannedMinutes: 30, day: day, context: context)!
        ActivityTracker.finish(s, quantity: 5, context: context)

        XCTAssertEqual(prep().count, 1, "the first PrepSession this app has ever written")
        XCTAssertEqual(prep().first?.category, .productSense)
        XCTAssertEqual(s.quantity, 5)
    }

    func testPrepReadingWritesTheReadingCategoryNotAPracticeOne() {
        let s = ActivityTracker.start(blockKey: "r", title: "Interview prep — Reading",
                                      plannedMinutes: 90, day: Date(), context: context)!
        ActivityTracker.finish(s, quantity: 18, context: context)
        XCTAssertEqual(prep().first?.category, .reading,
                       "prep reading is prep, but it is not practice")
    }

    /// ReadingLog is book-linked and belongs to the library. Inventing a book
    /// to satisfy it would put a phantom row on the shelf — the session is the
    /// evidence instead.
    func testTheReadingHabitWritesNoLibraryRow() {
        let s = ActivityTracker.start(blockKey: "h", title: "Reading (habit)",
                                      plannedMinutes: 60, day: Date(), context: context)!
        ActivityTracker.finish(s, quantity: 24, context: context)
        XCTAssertTrue(((try? context.fetch(FetchDescriptor<ReadingLog>())) ?? []).isEmpty)
        XCTAssertTrue(prep().isEmpty, "nor is the habit mistaken for interview prep")
        XCTAssertEqual(s.quantity, 24)
    }

    func testLoggingTheSameBlockTwiceDoesNotDoubleCount() {
        let day = Date()
        let s = ActivityTracker.start(blockKey: "ps", title: "Interview prep — Product Sense",
                                      plannedMinutes: 30, day: day, context: context)!
        ActivityTracker.finish(s, quantity: 5, context: context)
        ActivityTracker.finish(s, quantity: 6, context: context)
        XCTAssertEqual(prep().count, 1, "one evidence row per kind per day")
    }

    func testAnAutoClosedSessionWritesNoEvidence() {
        let s = ActivityTracker.start(blockKey: "ps", title: "Interview prep — Execution",
                                      plannedMinutes: 30, day: Date(), context: context)!
        ActivityTracker.autoClose(s, context: context)
        XCTAssertTrue(prep().isEmpty,
                      "a session of unknown length that may not have happened is not a fact")
    }

    func testRetroactiveLoggingWritesEvidenceToo() {
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        ActivityTracker.logRetroactively(blockKey: "ps", title: "Interview prep — Behavioral",
                                         plannedMinutes: 30, day: day, quantity: 4, context: context)
        XCTAssertEqual(prep().count, 1)
        XCTAssertEqual(prep().first?.category, .behavioral)
    }

    // MARK: the backfill window

    func testTheWindowIsTodayAndYesterdayOnly() {
        let now = Date()
        let cal = Calendar.current
        XCTAssertTrue(ActivityTracker.isWithinBackfillWindow(now, now: now))
        XCTAssertTrue(ActivityTracker.isWithinBackfillWindow(
            cal.date(byAdding: .day, value: -1, to: now)!, now: now))
        XCTAssertFalse(ActivityTracker.isWithinBackfillWindow(
            cal.date(byAdding: .day, value: -2, to: now)!, now: now),
            "Friday afternoon is out of reach by Monday — worth knowing going in")
        XCTAssertFalse(ActivityTracker.isWithinBackfillWindow(
            cal.date(byAdding: .day, value: 1, to: now)!, now: now),
            "tomorrow hasn't happened")
    }

    // MARK: adherence reads sessions

    func testACompletedSessionMarksItsBlockDone() {
        let block = GeneratedBlock(title: "Reading habit", startTime: "18:00", endTime: "19:00",
                                   note: nil, isAnchor: false, kind: "activity")
        var e = DayEvidence()
        XCTAssertEqual(AdherenceEngine.infer(plan: GeneratedPlan(blocks: [block], dropped: [],
                                                                shrunk: [], summary: "", boundaryTime: nil),
                                             evidence: e), [.skipped])
        e.sessionsCompleted = [AdherenceEngine.key(block)]
        XCTAssertEqual(AdherenceEngine.infer(plan: GeneratedPlan(blocks: [block], dropped: [],
                                                                shrunk: [], summary: "", boundaryTime: nil),
                                             evidence: e), [.done],
                       "you did it and said so — no inference required")
    }
}
