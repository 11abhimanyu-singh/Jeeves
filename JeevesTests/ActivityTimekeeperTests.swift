//
//  ActivityTimekeeperTests.swift
//  JeevesTests
//
//  The chain, and the backstop that stops one forgotten tap costing the day.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class ActivityTimekeeperTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() {
        super.setUp()
        let schema = Schema([ActivitySession.self, DailyPlanState.self, PrepSession.self,
                             JobApplication.self, LeisureLog.self, Trip.self, AppEvent.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try! ModelContainer(for: schema, configurations: [config])
    }
    override func tearDown() { container = nil; super.tearDown() }

    private func session(planned: Int, startedAt: Date) -> ActivitySession {
        ActivitySession(day: startedAt, blockKey: "k", title: "Interview prep — Execution",
                        plannedMinutes: planned, unit: .questions, startedAt: startedAt)
    }

    // MARK: the backstop

    func testASessionClosesThirtyMinutesPastItsPlan() {
        let t0 = Date()
        let s = session(planned: 60, startedAt: t0)
        XCTAssertFalse(ActivityTimekeeper.shouldAutoClose(s, now: t0.addingTimeInterval(60 * 60)),
                       "on time is not late")
        XCTAssertFalse(ActivityTimekeeper.shouldAutoClose(s, now: t0.addingTimeInterval(89 * 60)),
                       "29 minutes over still gets the benefit of the doubt")
        XCTAssertTrue(ActivityTimekeeper.shouldAutoClose(s, now: t0.addingTimeInterval(90 * 60)),
                      "planned + 30 is the limit")
    }

    /// Without a plan there is nothing to run past, so it falls back to the
    /// watchdog's four hours rather than never closing at all.
    func testAnUnplannedSessionFallsBackToFourHours() {
        let t0 = Date()
        let s = session(planned: 0, startedAt: t0)
        XCTAssertFalse(ActivityTimekeeper.shouldAutoClose(s, now: t0.addingTimeInterval(3 * 3600)))
        XCTAssertTrue(ActivityTimekeeper.shouldAutoClose(s, now: t0.addingTimeInterval(4 * 3600)))
    }

    func testTheSweepClosesStaleSessionsWithoutInventingADuration() {
        let t0 = Date().addingTimeInterval(-120 * 60)
        let s = session(planned: 60, startedAt: t0)
        context.insert(s)
        try? context.save()

        let closed = ActivityTimekeeper.sweepStale(context: context)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(s.state, .needsDetail)
        XCTAssertNil(s.driftMinutes, "it knows when it started and nothing else")
        XCTAssertTrue(((try? context.fetch(FetchDescriptor<PrepSession>())) ?? []).isEmpty,
                      "and an unknown session is not written down as fact")
    }

    func testTheSweepLeavesAHealthySessionAlone() {
        let s = session(planned: 60, startedAt: Date())
        context.insert(s)
        try? context.save()
        XCTAssertTrue(ActivityTimekeeper.sweepStale(context: context).isEmpty)
        XCTAssertTrue(s.isLive)
    }

    // MARK: withheld — the difference between a miss and a gap

    func testAWithheldBlockIsUnknownNotSkipped() {
        let block = GeneratedBlock(title: "Interview prep — Strategy", startTime: "14:00",
                                   endTime: "14:45", note: nil, isAnchor: false, kind: "activity")
        let plan = GeneratedPlan(blocks: [block], dropped: [], shrunk: [], summary: "", boundaryTime: nil)

        // Nobody asked, nothing logged: today's rule would call that skipped.
        var e = DayEvidence()
        XCTAssertEqual(AdherenceEngine.infer(plan: plan, evidence: e), [.skipped])

        e.neverAsked = [AdherenceEngine.key(block)]
        XCTAssertEqual(AdherenceEngine.infer(plan: plan, evidence: e), [.unknown],
                       "the app failed to prompt — that is its gap, not the user's miss")
    }

    func testWithheldKeysRoundTripOnTheDayState() {
        let day = Date()
        ActivityTimekeeper.markWithheld("a", on: day, context: context)
        ActivityTimekeeper.markWithheld("b", on: day, context: context)
        ActivityTimekeeper.markWithheld("a", on: day, context: context)   // idempotent
        XCTAssertEqual(DailyPlanState.forDay(day, in: context).withheldKeys, ["a", "b"])

        ActivityTimekeeper.clearWithheld(on: day, context: context)
        XCTAssertTrue(DailyPlanState.forDay(day, in: context).withheldKeys.isEmpty,
                      "stopping releases the queue AND the record of holding it")
    }

    // MARK: travel days

    func testTravelDaysAreDetected() {
        let day = Date().startOfDay
        XCTAssertFalse(ActivityTimekeeper.isTravelDay(day, context: context))
        context.insert(Trip(title: "Wayanad", startDate: day, endDate: day.addingTimeInterval(86_400)))
        try? context.save()
        XCTAssertTrue(ActivityTimekeeper.isTravelDay(day, context: context),
                      "no nudges while you're driving to Wayanad")
    }

    // MARK: categories

    /// setNotificationCategories REPLACES the whole set, so a second
    /// registration elsewhere would silently delete "Close it / Still going"
    /// from the stuck-workout nudge. They are registered together.
    func testEveryCategoryIsRegisteredInOnePlace() {
        let ids = Set(ActivityTimekeeper.categories().map(\.identifier))
        XCTAssertTrue(ids.contains(ActivityTimekeeper.startCategory))
        XCTAssertTrue(ids.contains(ActivityTimekeeper.stopCategory))
        XCTAssertEqual(WorkoutWatchdog.stuckCategory().identifier, WorkoutWatchdog.category)
        XCTAssertFalse(ids.contains(WorkoutWatchdog.category),
                       "the watchdog's own category is added alongside, not duplicated here")
    }

    func testTheStartNudgeOffersSnoozeAndSkipSeparately() {
        let start = ActivityTimekeeper.categories()
            .first { $0.identifier == ActivityTimekeeper.startCategory }
        let actions = Set(start?.actions.map(\.identifier) ?? [])
        XCTAssertTrue(actions.contains(ActivityTimekeeper.startAction))
        XCTAssertTrue(actions.contains(ActivityTimekeeper.skipAction))
    }
}
