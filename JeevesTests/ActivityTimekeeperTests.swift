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

    // MARK: the day stamp on a notification id
    //
    // Why this exists: the user reported getting NO activity nudges at all,
    // ever. Two defects compounded. `clear(for:)` took a date and never read
    // it, deleting every pending nudge for every day — and it is the first
    // statement of scheduleDay, so planning ANY day wiped every other day's
    // chain. With a rolling 4-day auto-plan window, today's nudges were removed
    // about two days before today began. And AdherenceEngine.key is
    // "HH:MM|Title" with no date, so the same routine block on two days
    // produced the SAME identifier and the later commit overwrote the earlier
    // one on `add`. Fixing either alone still delivers nothing.

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
    }

    func testTwoDaysNeverShareANotificationIdentifier() {
        let key = "09:00|Chores"   // the same routine block, two mornings running
        let mon = ActivityTimekeeper.dayPrefix(for: day(2026, 8, 3)) + "start." + key
        let tue = ActivityTimekeeper.dayPrefix(for: day(2026, 8, 4)) + "start." + key
        XCTAssertNotEqual(mon, tue,
                          "identical ids mean committing tomorrow overwrites today's pending request")
    }

    func testTheStampIsStableAcrossTimesOfTheSameDay() {
        let cal = Calendar.current
        let morning = cal.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 0, minute: 1))!
        let night = cal.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 23, minute: 59))!
        XCTAssertEqual(ActivityTimekeeper.dayPrefix(for: morning),
                       ActivityTimekeeper.dayPrefix(for: night),
                       "a day's own nudges must all clear together, whatever hour scheduled them")
    }

    /// The clear filters on this prefix. If one day's stamp were a prefix of
    /// another's, clearing the shorter would take the longer with it — which is
    /// the exact bug, reintroduced by a subtler route.
    func testNoDayStampIsAPrefixOfAnother() {
        let stamps = [day(2026, 8, 3), day(2026, 8, 30), day(2026, 1, 1), day(2026, 12, 31), day(2027, 1, 1)]
            .map { ActivityTimekeeper.dayPrefix(for: $0) }
        for a in stamps {
            for b in stamps where a != b {
                XCTAssertFalse(b.hasPrefix(a), "\(b) starts with \(a) — clearing one would clear both")
            }
        }
        XCTAssertEqual(Set(stamps).count, stamps.count, "every day needs its own stamp")
    }

    /// THE regression, stated directly: planning one day must not clear another
    /// day's nudges. This is what silenced the feature completely — the auto
    /// planner commits a rolling four-day window, so every pass wiped the days
    /// around it and today was emptied before today began.
    func testClearingOneDayLeavesEveryOtherDayAlone() {
        let mon = day(2026, 8, 3), tue = day(2026, 8, 4)
        let pending = [
            ActivityTimekeeper.dayPrefix(for: mon) + "start.09:00|Chores",
            ActivityTimekeeper.dayPrefix(for: mon) + "start.10:00|Interview prep — Reading",
            ActivityTimekeeper.dayPrefix(for: tue) + "start.09:00|Chores",
            "jeeves-20260803-2",            // a block reminder — different scheme entirely
            "jeeves.workout.stuck",         // the watchdog
        ]

        let cleared = ActivityTimekeeper.idsToClear(pending: pending, for: tue)
        XCTAssertEqual(cleared, [ActivityTimekeeper.dayPrefix(for: tue) + "start.09:00|Chores"],
                       "planning Tuesday must touch nothing but Tuesday")

        let survivors = pending.filter { !cleared.contains($0) }
        XCTAssertEqual(survivors.count, 4)
        XCTAssertTrue(survivors.contains { $0.hasPrefix(ActivityTimekeeper.dayPrefix(for: mon)) },
                      "Monday's chain must still be armed after Tuesday is planned")
        XCTAssertTrue(survivors.contains("jeeves.workout.stuck"),
                      "and the activity clear has no business touching other features")
    }

    func testClearingADayWithNothingPendingRemovesNothing() {
        let pending = [ActivityTimekeeper.dayPrefix(for: day(2026, 8, 3)) + "start.09:00|Chores"]
        XCTAssertEqual(ActivityTimekeeper.idsToClear(pending: pending, for: day(2026, 8, 9)), [])
    }

    func testTheStampIsZeroPaddedSoItSortsAndMatchesPredictably() {
        XCTAssertEqual(ActivityTimekeeper.dayPrefix(for: day(2026, 1, 5)), "jeeves.activity.20260105.")
        XCTAssertEqual(ActivityTimekeeper.dayPrefix(for: day(2026, 12, 31)), "jeeves.activity.20261231.")
    }

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
