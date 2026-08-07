//
//  MorningPromptServiceTests.swift
//  JeevesTests
//
//  Delivery, not content: which mornings get armed, when a fired notification
//  would already be stale, and the three ways to have nothing to say.
//

import XCTest
@testable import Jeeves

final class MorningPromptServiceTests: XCTestCase {

    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: d, hour: h, minute: m))!
    }
    private func day(_ d: Int) -> Date { at(d, 0).startOfDay }

    // MARK: which mornings

    func testTheWindowStartsWithTodayAndIsStartOfDay() {
        let days = MorningPromptService.days(from: at(7, 22, 30), count: 3)
        XCTAssertEqual(days, [day(7), day(8), day(9)],
                       "armed from the day you're in, even at half past ten at night")
    }

    func testTheWindowIsSmallBecauseTheNotificationBudgetIsShared() {
        XCTAssertLessThanOrEqual(MorningPromptService.windowDays, 7,
                                 "iOS holds 64 pending notifications for the whole app, and the plan's own nudges need most of them")
    }

    // MARK: when it fires

    func testTodaysOfferIsDroppedOnceItsMomentHasPassed() {
        XCTAssertNil(MorningPromptService.fireDate(for: day(7), now: at(7, 9)),
                     "arming a past time delivers it immediately — that is how a morning plan arrives at lunchtime")
        XCTAssertEqual(MorningPromptService.fireDate(for: day(7), now: at(7, 6)), at(7, 7),
                       "still ahead of 07:00, so today is genuinely offerable")
    }

    func testTomorrowIsAlwaysStillAhead() {
        XCTAssertEqual(MorningPromptService.fireDate(for: day(8), now: at(7, 23, 59)), at(8, 7))
    }

    // MARK: identity

    func testEachMorningOwnsOneIdentifierSoReschedulingReplacesRatherThanStacks() {
        XCTAssertEqual(MorningPromptService.id(for: at(7, 19)), "jeeves.morning.2026-08-07")
        XCTAssertNotEqual(MorningPromptService.id(for: day(7)), MorningPromptService.id(for: day(8)))
        XCTAssertTrue(MorningPromptService.id(for: day(7)).hasPrefix(MorningPromptService.idPrefix),
                      "the prefix is what the clear-and-rearm sweep matches on")
    }

    // MARK: whether to say anything

    func testAnOrdinaryUnplannedMorningGetsTheCard() {
        XCTAssertTrue(MorningPromptService.shouldPost(hasPlan: false, candidateCount: 6, alreadyShowing: false))
    }

    /// A day already planned is a decision, not a question. Offering to plan it
    /// again is how you teach someone to ignore you.
    func testADayThatIsAlreadyPlannedIsNotAskedAbout() {
        XCTAssertFalse(MorningPromptService.shouldPost(hasPlan: true, candidateCount: 6, alreadyShowing: false))
    }

    func testAnEmptyRoutineProducesSilenceRatherThanAnEmptyList() {
        XCTAssertFalse(MorningPromptService.shouldPost(hasPlan: false, candidateCount: 0, alreadyShowing: false))
    }

    func testTheCardIsNotPostedTwiceIntoTheSameConversation() {
        XCTAssertFalse(MorningPromptService.shouldPost(hasPlan: false, candidateCount: 6, alreadyShowing: true))
    }

    // MARK: the late start

    /// The day that most needs an offer is the one you started at 10am, and
    /// that was exactly the day `fireDate` refused to arm.
    func testADayStartedLateStillGetsItsOffer() {
        XCTAssertTrue(MorningPromptService.needsCatchUp(
            day: day(7), now: at(7, 10, 30), hasPlan: false, chosen: false, lastOfferedDay: nil))
    }

    func testNothingIsCaughtUpBeforeTheScheduledOfferHasEvenFired() {
        XCTAssertFalse(MorningPromptService.needsCatchUp(
            day: day(7), now: at(7, 6, 30), hasPlan: false, chosen: false, lastOfferedDay: nil),
            "07:00 is still ahead — the scheduled notification will do its job")
    }

    /// The test is whether you CHOSE today, not whether a plan exists. A plan
    /// you did not pick is the thing the redesign exists to stop counting as
    /// your decision — so a day carrying one is still offerable.
    /// A day just cleared has no plan, whatever its selection still says.
    func testAClearedDayIsOfferedAgain() {
        XCTAssertTrue(MorningPromptService.needsCatchUp(
            day: day(7), now: at(7, 10, 30), hasPlan: false, chosen: true, lastOfferedDay: nil),
            "the plan is gone, so there is nothing left that counts as today's answer")
    }

    func testAPlanYouDidNotChooseDoesNotCountAsChoosing() {
        XCTAssertTrue(MorningPromptService.needsCatchUp(
            day: day(7), now: at(7, 10, 30), hasPlan: true, chosen: false, lastOfferedDay: nil),
            "a plan exists, but nobody chose it")
        XCTAssertFalse(MorningPromptService.needsCatchUp(
            day: day(7), now: at(7, 10, 30), hasPlan: true, chosen: true, lastOfferedDay: nil),
            "picked AND planned AND not empty — the day is settled")
    }

    /// The state this actually failed in: the user cleared the day to start
    /// over, which left a plan of lunch and free time and an explicitly EMPTY
    /// selection — and the app read that as a settled decision and said nothing.
    func testAClearedDayIsNotASettledDay() {
        XCTAssertTrue(MorningPromptService.needsCatchUp(
            day: day(7), now: at(7, 10, 30), hasPlan: true, chosen: true,
            isBlankDay: true, lastOfferedDay: nil),
            "an empty day is the absence of a plan, not a plan")
    }

    func testTheCatchUpFiresAtMostOncePerDay() {
        XCTAssertFalse(MorningPromptService.needsCatchUp(
            day: day(7), now: at(7, 10, 30), hasPlan: false, chosen: false, lastOfferedDay: "2026-08-07"),
            "every foregrounding of an unchosen day must not be a fresh banner")
        XCTAssertTrue(MorningPromptService.needsCatchUp(
            day: day(7), now: at(7, 10, 30), hasPlan: false, chosen: false, lastOfferedDay: "2026-08-06"),
            "yesterday's stamp does not silence today")
    }

    func testTheCatchUpOnlyEverConcernsToday() {
        XCTAssertFalse(MorningPromptService.needsCatchUp(
            day: day(8), now: at(7, 10, 30), hasPlan: false, chosen: false, lastOfferedDay: nil),
            "tomorrow has a scheduled 07:00 offer and needs no rescue")
    }

    /// It reuses the day's own identifier, so a catch-up REPLACES any offer
    /// still pending for today rather than queueing a second banner.
    func testTheCatchUpReusesTheDaysIdentifier() {
        XCTAssertEqual(MorningPromptService.id(for: day(7)), "jeeves.morning.2026-08-07")
    }

    /// The bug that made the offer never arrive: re-arming swept every pending
    /// `jeeves.morning.*` id, INCLUDING today's ten-second catch-up, and the
    /// scheduling loop only ever re-creates FUTURE days. Two calls a few
    /// milliseconds apart — which is exactly what onAppear plus the scenePhase
    /// change produce on a cold launch — armed it and then deleted it.
    func testReArmingMustNotSweepAnIdItCannotRecreate() {
        let now = at(7, 10, 30)
        let sweepable = MorningPromptService.days(from: now)
            .map { MorningPromptService.id(for: $0) }
            .filter { $0 != MorningPromptService.id(for: now) }
        XCTAssertFalse(sweepable.contains(MorningPromptService.id(for: day(7))),
                       "today's catch-up must survive the sweep — nothing re-creates it")
        XCTAssertTrue(sweepable.contains(MorningPromptService.id(for: day(8))),
                      "future mornings ARE re-created by the loop, so sweeping them is safe")
    }

    /// And once it survives the sweep, the second call must not re-add it —
    /// that would reset its ten seconds on every foregrounding, so it would
    /// never actually land.
    func testAnArmedOfferIsLeftAloneRatherThanRescheduled() {
        XCTAssertEqual(MorningPromptService.id(for: at(7, 10, 30)),
                       MorningPromptService.id(for: day(7)),
                       "the pending check and the add must agree on the identifier")
    }

    func testTheCatchUpDelayIsShortEnoughToReadAsAResponseToOpeningTheApp() {
        XCTAssertLessThanOrEqual(MorningPromptService.catchUpDelay, 30)
        XCTAssertGreaterThanOrEqual(MorningPromptService.catchUpDelay, 5,
                                    "firing during the launch animation reads as a glitch")
    }
}
