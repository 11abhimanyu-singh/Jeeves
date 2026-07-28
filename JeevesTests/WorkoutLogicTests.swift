//
//  WorkoutLogicTests.swift
//  JeevesTests
//
//  Pure logic behind the unified Workout container: the day-grouping the
//  migration uses to merge a day's lift sessions into one workout, and the
//  watch-activity-code → WorkoutType mapping the handoff relies on.
//

import XCTest
@testable import Jeeves

final class WorkoutLogicTests: XCTestCase {

    private var cal: Calendar { Calendar(identifier: .gregorian) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    // MARK: Day grouping (migration)

    func testGroupedByDayMergesSameDaySessions() {
        let dates = [date(2026, 7, 27, 8), date(2026, 7, 27, 19), date(2026, 7, 28, 7)]
        let groups = Workout.groupedByDay(dates, date: { $0 }, calendar: cal)
        XCTAssertEqual(groups.count, 2, "two calendar days → two workouts")
        XCTAssertEqual(groups[cal.startOfDay(for: date(2026, 7, 27))]?.count, 2)
        XCTAssertEqual(groups[cal.startOfDay(for: date(2026, 7, 28))]?.count, 1)
    }

    func testGroupedByDaySplitsAroundMidnight() {
        // 23:59 and 00:01 the next day are different workouts.
        let lateNight = cal.date(from: DateComponents(year: 2026, month: 7, day: 27, hour: 23, minute: 59))!
        let earlyNext = cal.date(from: DateComponents(year: 2026, month: 7, day: 28, hour: 0, minute: 1))!
        let groups = Workout.groupedByDay([lateNight, earlyNext], date: { $0 }, calendar: cal)
        XCTAssertEqual(groups.count, 2)
    }

    func testGroupedByDayEmptyInput() {
        let groups = Workout.groupedByDay([Date](), date: { $0 }, calendar: cal)
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: Watch activity mapping (handoff)

    func testActivityCodeMapsToType() {
        XCTAssertEqual(WorkoutType.from(activity: "strength"), .lift)
        XCTAssertEqual(WorkoutType.from(activity: "walkIndoor"), .walk)
        XCTAssertEqual(WorkoutType.from(activity: "walkOutdoor"), .walk)
        XCTAssertEqual(WorkoutType.from(activity: "run"), .run)
        XCTAssertEqual(WorkoutType.from(activity: "somethingNew"), .run,
                       "unknown codes fall back to run (the original activity)")
    }

    func testActivityCodeTitles() {
        XCTAssertEqual(WorkoutType.title(forActivity: "strength"), "Lifting")
        XCTAssertEqual(WorkoutType.title(forActivity: "walkIndoor"), "Indoor Walk")
        XCTAssertEqual(WorkoutType.title(forActivity: "walkOutdoor"), "Outdoor Walk")
        XCTAssertEqual(WorkoutType.title(forActivity: "run"), "Run")
    }
}
