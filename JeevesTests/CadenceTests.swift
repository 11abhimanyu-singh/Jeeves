//
//  CadenceTests.swift
//  JeevesTests
//
//  One rule under test above all others: an empty cadence means EVERY day.
//  That is what lets this ship without a backfill — every stored row keeps the
//  behaviour it had before — so if it ever stops being true, a migration that
//  was never written silently becomes required.
//

import XCTest
@testable import Jeeves

final class CadenceTests: XCTestCase {

    /// Foundation weekday numbers: Sunday = 1 … Saturday = 7.
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // 2026-08-03 is a Monday, so 03→09 August is one clean Mon–Sun week.
    private let monday    = DateComponents(year: 2026, month: 8, day: 3)
    private func aug(_ d: Int) -> Date { day(2026, 8, d) }

    // MARK: the default that makes this safe to ship

    func testAnEmptyCadenceMeansEveryDayNotNoDays() {
        let c = Cadence.everyDay
        XCTAssertTrue(c.isEveryDay)
        for d in 3...9 {
            XCTAssertTrue(c.isDue(on: aug(d)),
                          "an unset cadence must behave exactly as the row did before this feature")
        }
    }

    func testAGarbledRawStringFallsBackToEveryDayRatherThanToSilence() {
        XCTAssertTrue(Cadence(raw: "banana").isEveryDay,
                      "a corrupt field should over-schedule visibly, never empty the week silently")
        XCTAssertTrue(Cadence(raw: "").isEveryDay)
    }

    func testWeekdayNumbersFollowFoundationSundayIsOne() {
        XCTAssertEqual(Calendar.current.component(.weekday, from: aug(3)), 2, "3 Aug 2026 is a Monday")
        XCTAssertEqual(Calendar.current.component(.weekday, from: aug(9)), 1, "9 Aug 2026 is a Sunday")
    }

    // MARK: which days it lands on

    func testACadenceLandsOnlyOnItsOwnDaysAcrossAFullWeek() {
        let monWedFri = Cadence(weekdays: [2, 4, 6])
        let due = (3...9).filter { monWedFri.isDue(on: aug($0)) }
        XCTAssertEqual(due, [3, 5, 7], "Mon, Wed, Fri — and nothing on Tue, Thu, or the weekend")
    }

    func testTheWeekBoundaryIsNotASpecialCase() {
        let sundayOnly = Cadence(weekdays: [1])
        XCTAssertTrue(sundayOnly.isDue(on: aug(9)), "Sunday closes this week")
        XCTAssertTrue(sundayOnly.isDue(on: aug(16)), "and opens Foundation's next one — same answer")
        XCTAssertFalse(sundayOnly.isDue(on: aug(10)), "Monday is not Sunday, whichever week it belongs to")
    }

    func testOutOfRangeWeekdaysAreDiscardedRatherThanStored() {
        XCTAssertEqual(Cadence(weekdays: [0, 2, 8, 99]).weekdays, [2],
                       "only 1...7 are weekdays; anything else is corruption, not a day")
    }

    func testRawRoundTripsSoTheStoredStringSurvivesAReadAndAWrite() {
        let c = Cadence(weekdays: [6, 2, 4])
        XCTAssertEqual(c.raw, "2,4,6", "sorted, so the stored value is stable across edits")
        XCTAssertEqual(Cadence(raw: c.raw), c)
    }

    // MARK: neglect ordering

    func testANeverCompletedActivityIsDueImmediatelyAndSortsAsMostNeglected() {
        let daily = Cadence.everyDay
        let overdue = daily.daysOverdue(since: nil, on: aug(9), lookbackDays: 28)
        XCTAssertEqual(overdue, 29, "never done counts every due day in the window, so it outranks everything")
        XCTAssertGreaterThan(overdue, daily.daysOverdue(since: aug(8), on: aug(9)),
                             "a brand-new activity must outrank one done yesterday")
    }

    func testTheDayYouDidItIsNotADayYouOwe() {
        XCTAssertEqual(Cadence.everyDay.daysOverdue(since: aug(9), on: aug(9)), 0,
                       "done today is not overdue today")
        XCTAssertEqual(Cadence.everyDay.daysOverdue(since: aug(8), on: aug(9)), 1)
    }

    func testOverdueCountsOnlyTheDaysTheActivityWasActuallyDue() {
        let monWedFri = Cadence(weekdays: [2, 4, 6])
        // Last done Monday 3rd; by Sunday 9th only Wed 5th and Fri 7th were owed.
        XCTAssertEqual(monWedFri.daysOverdue(since: aug(3), on: aug(9)), 2,
                       "a Tuesday it never runs on is not a day it missed")
    }

    // MARK: display

    func testDescriptionNamesTheCommonShapesRatherThanListingThem() {
        XCTAssertEqual(Cadence.everyDay.description, "Every day")
        XCTAssertEqual(Cadence(weekdays: [2, 3, 4, 5, 6]).description, "Weekdays")
        XCTAssertEqual(Cadence(weekdays: [1, 7]).description, "Weekends")
    }

    func testDescriptionReadsMondayFirstToMatchTheChipStrip() {
        XCTAssertEqual(Cadence(weekdays: [1, 2, 4]).description, "Mon, Wed, Sun",
                       "Sunday is weekday 1 but it reads last, where the strip puts it")
        XCTAssertEqual(Cadence.initials.count, 7)
        XCTAssertEqual(Cadence.orderedWeekdays, [2, 3, 4, 5, 6, 7, 1])
    }
}
