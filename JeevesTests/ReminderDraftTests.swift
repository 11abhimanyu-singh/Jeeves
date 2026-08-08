//
//  ReminderDraftTests.swift
//  JeevesTests
//
//  What day a new reminder lands on.
//
//  The add sheet used to build its fire date from `Date()` with no way to say
//  otherwise, so the entire expressible set was four chip times today plus the
//  same four tomorrow — eight reminders, and no way to ask for anything on
//  Thursday. The edit sheet had a full date picker the whole time; only the
//  ADD path was crippled.
//

import XCTest
@testable import Jeeves

final class ReminderDraftTests: XCTestCase {

    private let cal = Calendar.current

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func parts(_ date: Date) -> (y: Int, m: Int, d: Int, h: Int, min: Int) {
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    // MARK: a one-off can finally name its day

    func testAOneOffLandsOnTheDayThatWasChosenNotToday() {
        let now = at(2026, 8, 6, 11, 20)          // Thursday
        let fire = RemindersListView.fireDate(day: at(2026, 8, 20), hour: 18, minute: 0,
                                              recurrence: .once, now: now, cal: cal)
        let p = parts(fire)
        XCTAssertEqual([p.y, p.m, p.d, p.h, p.min], [2026, 8, 20, 18, 0],
                       "a fortnight out was simply not expressible before")
    }

    /// The roll-forward is why a 9 AM reminder created at 11 AM still fires.
    /// It must survive — but only for TODAY.
    func testATimeAlreadyGoneTodayRollsToTomorrow() {
        let now = at(2026, 8, 6, 11, 20)
        let fire = RemindersListView.fireDate(day: at(2026, 8, 6), hour: 9, minute: 0,
                                              recurrence: .once, now: now, cal: cal)
        XCTAssertEqual(parts(fire).d, 7, "9 AM has gone, so it means tomorrow morning")
    }

    func testATimeStillAheadTodayStaysToday() {
        let now = at(2026, 8, 6, 11, 20)
        let fire = RemindersListView.fireDate(day: at(2026, 8, 6), hour: 18, minute: 0,
                                              recurrence: .once, now: now, cal: cal)
        XCTAssertEqual(parts(fire).d, 6)
    }

    /// The roll-forward must not fire on a deliberately chosen day, or picking
    /// a date would quietly move it — undoing the one thing this fixes.
    func testAChosenFutureDayIsNeverRolledForward() {
        let now = at(2026, 8, 6, 23, 50)
        let fire = RemindersListView.fireDate(day: at(2026, 8, 7), hour: 9, minute: 0,
                                              recurrence: .once, now: now, cal: cal)
        XCTAssertEqual(parts(fire).d, 7, "9 AM tomorrow is ahead of us; nothing to roll")
    }

    // MARK: weekly stops guessing its weekday

    /// ReminderScheduler reads the repeat weekday straight off `fireAt`, so the
    /// anchor has to BE the day the user picked. Before, `fireAt` was always
    /// today, which is why Weekly silently meant "the weekday you happened to
    /// create it on" and the sheet never said so.
    func testWeeklyAnchorsToTheChosenWeekdayNotTheCreationDay() {
        let now = at(2026, 8, 6, 11, 20)             // Thursday
        let sunday = at(2026, 8, 9)
        let fire = RemindersListView.fireDate(day: sunday, hour: 20, minute: 30,
                                              recurrence: .weekly, now: now, cal: cal)
        XCTAssertEqual(cal.component(.weekday, from: fire), 1, "Sunday is weekday 1")
        XCTAssertEqual(parts(fire).h, 20)
        XCTAssertEqual(parts(fire).min, 30)
        XCTAssertNotEqual(cal.component(.weekday, from: fire),
                          cal.component(.weekday, from: now),
                          "the whole point is that it is NOT the day it was created on")
    }

    // MARK: every N days
    //
    // The odd one out. Every other recurrence is a DateComponents match the OS
    // repeats forever, but no components describe "every third day" — a period
    // that isn't a week aligns to no calendar field. So this one is a rolling
    // window of concrete dates, and the arithmetic below is the only thing
    // standing between the user and a reminder that drifts.

    func testItWalksForwardFromTheAnchorInSteps() {
        let anchor = at(2026, 8, 3, 9, 0)   // Monday
        let dates = ReminderRecurrence.everyNDays.occurrences(
            anchor: anchor, intervalDays: 3, count: 4, now: at(2026, 8, 3, 8, 0), cal: cal)
        XCTAssertEqual(dates.map { parts($0).d }, [3, 6, 9, 12])
        XCTAssertTrue(dates.allSatisfy { parts($0).h == 9 }, "the time of day never drifts")
    }

    /// The rhythm stays pinned to the day the user chose. Rescheduling happens
    /// on every launch, and if the walk restarted from "now" each time, an
    /// every-3-days reminder would silently re-phase to whichever day the app
    /// happened to be opened on.
    func testReschedulingLaterDoesNotRePhaseTheRhythm() {
        let anchor = at(2026, 8, 3, 9, 0)                 // Mon 3rd, every 3 days
        let asOfTuesday = ReminderRecurrence.everyNDays.occurrences(
            anchor: anchor, intervalDays: 3, count: 3, now: at(2026, 8, 4, 12, 0), cal: cal)
        XCTAssertEqual(asOfTuesday.map { parts($0).d }, [6, 9, 12],
                       "opening the app on Tuesday must not move the rhythm to Tuesdays")
    }

    func testAFortnightIsExpressibleWhichIsThePointOfTheWholeFeature() {
        let dates = ReminderRecurrence.everyNDays.occurrences(
            anchor: at(2026, 8, 1, 10, 0), intervalDays: 14, count: 3,
            now: at(2026, 8, 1, 9, 0), cal: cal)
        XCTAssertEqual(dates.map { parts($0).d }, [1, 15, 29],
                       "once a fortnight cannot be said in weekdays — that is why this exists")
    }

    func testAnIntervalOfZeroIsTreatedAsDailyRatherThanLoopingForever() {
        let dates = ReminderRecurrence.everyNDays.occurrences(
            anchor: at(2026, 8, 3, 9, 0), intervalDays: 0, count: 3,
            now: at(2026, 8, 3, 8, 0), cal: cal)
        XCTAssertEqual(dates.map { parts($0).d }, [3, 4, 5], "a zero step would never advance")
    }

    func testTheOtherRecurrencesGetNoOccurrenceList() {
        for r in [ReminderRecurrence.once, .daily, .weekdays, .weekly] {
            XCTAssertTrue(r.occurrences(anchor: at(2026, 8, 3), intervalDays: 3, count: 3, cal: cal).isEmpty,
                          "\(r.label) is a components match the OS repeats — it needs no window")
        }
        XCTAssertFalse(ReminderRecurrence.everyNDays.needsInterval == false)
    }

    // MARK: the repeats that don't take a day

    func testDailyAndWeekdaysCarryOnlyTheTimeOfDay() {
        let now = at(2026, 8, 6, 11, 20)
        for recurrence in [ReminderRecurrence.daily, .weekdays] {
            let fire = RemindersListView.fireDate(day: at(2026, 8, 20), hour: 7, minute: 45,
                                                  recurrence: recurrence, now: now, cal: cal)
            let p = parts(fire)
            XCTAssertEqual([p.h, p.min], [7, 45], "\(recurrence.label) keeps the time")
            XCTAssertEqual(p.d, 6, "\(recurrence.label) repeats from now — a start date means nothing to it")
        }
    }

    // MARK: the badge names the cadence

    /// `ReminderRecurrence.everyNDays.label` is the literal string "Every…" —
    /// correct beside the editor's Stepper, useless in a list row, where it
    /// named neither the cadence nor the interval. tools/visual-judge.py filed
    /// it as a clipped label and a layout fix was attempted; the text was never
    /// clipped. This is the checker that keeps the row honest.
    func testTheRowBadgeNamesTheActualInterval() {
        let r = Reminder(title: "Water the plants", fireAt: at(2026, 8, 8, 8, 0),
                         recurrence: .everyNDays, intervalDays: 3)
        XCTAssertEqual(RemindersListView.cadence(r), "Every 3 days")
        XCTAssertFalse(RemindersListView.cadence(r).contains("…"),
                       "the row has no Stepper to supply the number, so it must say it")
    }

    func testEveryOneDayIsSingular() {
        let r = Reminder(title: "Stretch", fireAt: at(2026, 8, 8, 8, 0),
                         recurrence: .everyNDays, intervalDays: 1)
        XCTAssertEqual(RemindersListView.cadence(r), "Every 1 day")
    }

    /// The other four recurrences already read correctly and must not change.
    func testTheFixedRecurrencesKeepTheirOwnWords() {
        for recurrence in [ReminderRecurrence.once, .daily, .weekdays, .weekly] {
            let r = Reminder(title: "x", fireAt: at(2026, 8, 8, 8, 0), recurrence: recurrence)
            XCTAssertEqual(RemindersListView.cadence(r), recurrence.label)
        }
    }
}
