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
}
