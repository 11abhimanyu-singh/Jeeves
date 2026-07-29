//
//  AnomalyScanTests.swift
//  JeevesTests
//
//  The behavioral rules, pinned against the real 28 July pattern found on
//  the device: a phone lift at 20:20, then two watch starts at 23:01 that
//  never ended — and the healthy day that must NOT trip any rule.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class AnomalyScanTests: XCTestCase {

    private var container: ModelContainer!

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Workout.self, AppEvent.self, CheckIn.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        return container.mainContext
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testStaleLiveWorkoutIsReported() throws {
        let context = try makeContext()
        let stuck = Workout(date: at(2026, 7, 28, 23, 1), type: .run, state: .live,
                            source: .watch, title: "Run")
        context.insert(stuck)

        let anomalies = AnomalyScan.scan(context: context, now: at(2026, 7, 30, 9, 0))

        XCTAssertTrue(anomalies.contains { $0.rule == "stale-live-workout" },
                      "a run live for 34 hours must be reported")
    }

    func testFreshLiveWorkoutIsNotReported() throws {
        // Mid-session is normal — a live row two hours old is someone at the gym.
        let context = try makeContext()
        context.insert(Workout(date: at(2026, 7, 30, 7, 0), type: .lift, state: .live,
                               source: .watch, title: "Lifting"))

        let anomalies = AnomalyScan.scan(context: context, now: at(2026, 7, 30, 9, 0))

        XCTAssertFalse(anomalies.contains { $0.rule == "stale-live-workout" })
    }

    func testManyStartsInOneDayAreNarrated() throws {
        let context = try makeContext()
        for (h, m) in [(20, 20), (23, 1), (23, 1), (23, 4)] {
            context.insert(AppEvent(date: at(2026, 7, 28, h, m), kind: .workoutStarted,
                                    detail: "Lifting"))
        }

        let anomalies = AnomalyScan.scan(context: context, now: at(2026, 7, 29, 9, 0))

        let hit = anomalies.first { $0.rule == "many-workout-starts" }
        XCTAssertNotNil(hit, "four starts in one day is the anomaly the user asked to see")
        XCTAssertTrue(hit!.title.contains("4 times"))
        XCTAssertTrue(hit!.detail.contains("20:20"), "the narrative carries the times")
    }

    func testTwoStartsArePauseAndResumeNotAnAnomaly() throws {
        let context = try makeContext()
        context.insert(AppEvent(date: at(2026, 7, 28, 7, 0), kind: .workoutStarted, detail: "Run"))
        context.insert(AppEvent(date: at(2026, 7, 28, 7, 40), kind: .workoutStarted, detail: "Run"))
        context.insert(AppEvent(date: at(2026, 7, 28, 8, 30), kind: .watchSummaryArrived, detail: "Run"))

        let anomalies = AnomalyScan.scan(context: context, now: at(2026, 7, 29, 9, 0))

        XCTAssertFalse(anomalies.contains { $0.rule == "many-workout-starts" })
    }

    func testStartWithoutEndIsReportedOnlyAfterTwelveHours() throws {
        let context = try makeContext()
        context.insert(AppEvent(date: at(2026, 7, 28, 23, 1), kind: .workoutStarted, detail: "Run"))

        let soon = AnomalyScan.scan(context: context, now: at(2026, 7, 29, 1, 0))
        XCTAssertFalse(soon.contains { $0.rule == "start-without-end" },
                       "two hours in, the session may simply still be running")

        let later = AnomalyScan.scan(context: context, now: at(2026, 7, 29, 20, 0))
        XCTAssertTrue(later.contains { $0.rule == "start-without-end" })
    }

    func testStartFollowedBySummaryIsClean() throws {
        let context = try makeContext()
        context.insert(AppEvent(date: at(2026, 7, 28, 7, 0), kind: .workoutStarted, detail: "Run"))
        context.insert(AppEvent(date: at(2026, 7, 28, 7, 45), kind: .watchSummaryArrived,
                                detail: "Run — 42 min, 148 bpm"))

        let anomalies = AnomalyScan.scan(context: context, now: at(2026, 7, 30, 9, 0))

        XCTAssertFalse(anomalies.contains { $0.rule == "start-without-end" })
    }

    func testCheckInWithoutWorkoutRowIsFlagged() throws {
        let context = try makeContext()
        context.insert(CheckIn(date: at(2026, 7, 27, 0, 0), workedOut: true, weightTraining: true,
                               stretching: false, mobility: false, cardio: false))

        let anomalies = AnomalyScan.scan(context: context, now: at(2026, 7, 30, 9, 0))

        XCTAssertTrue(anomalies.contains { $0.rule == "checkin-without-workout" })
    }
}
