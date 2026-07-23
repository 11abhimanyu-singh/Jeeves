//
//  AutoPlanServiceTests.swift
//  JeevesTests
//
//  Pure-logic coverage for the auto-planner: which upcoming days still need a
//  plan (fill gaps, never clobber), and when the next overnight wake lands.
//  The generation itself is network I/O and is left to the live path.
//

import XCTest
@testable import Jeeves

final class AutoPlanServiceTests: XCTestCase {

    private let today: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 22
        return Calendar.current.date(from: c)!.startOfDay
    }()
    private func day(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: today)!.startOfDay }

    func testEmptyPlansNeedsWholeWindow() {
        let needed = AutoPlanService.daysNeedingPlans(from: today, days: 4, plannedDays: [])
        XCTAssertEqual(needed, [day(0), day(1), day(2), day(3)])
    }

    func testFillsOnlyTheGaps() {
        // Today and tomorrow already planned → only the two after them remain.
        let planned: Set<Date> = [day(0), day(1)]
        let needed = AutoPlanService.daysNeedingPlans(from: today, days: 4, plannedDays: planned)
        XCTAssertEqual(needed, [day(2), day(3)], "a day with a plan is never re-planned")
    }

    func testFullyPlannedWindowNeedsNothing() {
        let planned: Set<Date> = [day(0), day(1), day(2), day(3)]
        XCTAssertTrue(AutoPlanService.daysNeedingPlans(from: today, days: 4, plannedDays: planned).isEmpty)
    }

    func testGapInTheMiddleIsFilled() {
        let planned: Set<Date> = [day(0), day(2)]  // today + day-after done, tomorrow missing
        XCTAssertEqual(AutoPlanService.daysNeedingPlans(from: today, days: 4, plannedDays: planned), [day(1), day(3)])
    }

    func testWindowStartsFromMidDay() {
        // `from` isn't midnight — the window must still be start-of-day aligned.
        let noonToday = Calendar.current.date(byAdding: .hour, value: 12, to: today)!
        let needed = AutoPlanService.daysNeedingPlans(from: noonToday, days: 2, plannedDays: [])
        XCTAssertEqual(needed, [day(0), day(1)])
    }

    // MARK: Next early-morning wake

    func testEarlyMorningLaterTodayWhenBeforeTarget() {
        let twoAM = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: today)!
        let next = AutoPlanService.nextEarlyMorning(after: twoAM)
        XCTAssertEqual(next, Calendar.current.date(bySettingHour: 4, minute: 30, second: 0, of: today))
    }

    func testEarlyMorningRollsToTomorrowWhenPastTarget() {
        let sixAM = Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: today)!
        let next = AutoPlanService.nextEarlyMorning(after: sixAM)
        XCTAssertEqual(next, Calendar.current.date(bySettingHour: 4, minute: 30, second: 0, of: day(1)))
    }
}
