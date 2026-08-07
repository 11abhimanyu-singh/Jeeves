//
//  MorningPromptTests.swift
//  JeevesTests
//
//  The offer made at 07:00, and the two things it must never do: decide the
//  day on the user's behalf, or wake them to say nothing.
//

import XCTest
@testable import Jeeves

final class MorningPromptTests: XCTestCase {

    /// 3 Aug 2026 is a Monday, 4 Aug a Tuesday, 8 Aug a Saturday.
    private func aug(_ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: d, hour: 7))!
    }

    private func row(_ name: String, _ minutes: Int, weekdays: Set<Int> = [],
                     enabled: Bool = true, order: Int, group: RoutineGroup = .none) -> RoutineActivity {
        let a = RoutineActivity(name: name, durationMinutes: minutes, tier: .important,
                                enabled: enabled, sortOrder: order, group: group)
        a.cadence = Cadence(weekdays: weekdays)
        return a
    }

    // MARK: what gets offered

    func testEverythingDueIsTickedAndTheRestIsOfferedUnticked() {
        let routine = [
            row("Chores", 60, order: 0),                    // every day
            row("Photography", 30, weekdays: [7], order: 1), // Saturdays
        ]
        let out = MorningPrompt.candidates(routine: routine, on: aug(4))   // Tuesday
        XCTAssertEqual(out.map(\.name), ["Chores", "Photography"],
                       "both are offered — the list is what you could do, not only what is due")
        XCTAssertEqual(out.map(\.dueToday), [true, false],
                       "only what the cadence says is due arrives ticked")
    }

    /// "I don't do this at all" and "not today" are different statements, and
    /// only the second belongs in a morning list.
    func testASwitchedOffActivityIsNotOfferedAtAll() {
        let routine = [row("Chores", 60, order: 0), row("Reading habit", 70, enabled: false, order: 1)]
        XCTAssertEqual(MorningPrompt.candidates(routine: routine, on: aug(4)).map(\.name), ["Chores"])
    }

    /// The gym is one anchor placed at a time you confirm, not a set of parts
    /// to tick.
    func testGymPartsAreNotOffered() {
        let routine = [
            row("Chores", 60, order: 0),
            row("Weightlifting", 70, order: 1, group: .gym),
            row("Cardio", 35, order: 2, group: .gym),
        ]
        XCTAssertEqual(MorningPrompt.candidates(routine: routine, on: aug(4)).map(\.name), ["Chores"])
    }

    func testTheListKeepsFillOrder() {
        let routine = [row("C", 30, order: 2), row("A", 30, order: 0), row("B", 30, order: 1)]
        XCTAssertEqual(MorningPrompt.candidates(routine: routine, on: aug(3)).map(\.name), ["A", "B", "C"])
    }

    // MARK: the notification

    func testTheNotificationNamesACountSoItCanBeDeclined() {
        XCTAssertEqual(MorningPrompt.notificationBody(dueCount: 6, gymAt: nil),
                       "6 activities due today. Tell me which ones and I'll build the day.")
        XCTAssertEqual(MorningPrompt.notificationBody(dueCount: 1, gymAt: nil),
                       "1 activity due today. Tell me which ones and I'll build the day.")
    }

    func testAConfirmedGymIsNamedBecauseItShapesEverythingElse() {
        let body = MorningPrompt.notificationBody(dueCount: 4, gymAt: 17 * 60)
        XCTAssertEqual(body, "4 activities due today. Gym at 17:00. Tell me which ones and I'll build the day.")
    }

    /// Silence is a feature. A day with nothing due and no gym has no offer to
    /// make, and waking someone to say so is the app talking to itself.
    func testAnEmptyDayMakesNoOffer() {
        XCTAssertNil(MorningPrompt.notificationBody(dueCount: 0, gymAt: nil))
        XCTAssertNotNil(MorningPrompt.notificationBody(dueCount: 0, gymAt: 11 * 60),
                        "a gym day is still a day worth opening")
    }

    // MARK: the opener

    func testTheOpenerSaysWhenTheDayCannotHoldWhatIsDue() {
        let over = MorningPrompt.chatOpener(dueCount: 6, totalMinutes: 525, freeMinutes: 450)
        XCTAssertTrue(over.contains("something will have to come off"), over)
        XCTAssertTrue(over.contains("8 h 45 m"), "name the real total, not a percentage")

        let fits = MorningPrompt.chatOpener(dueCount: 3, totalMinutes: 180, freeMinutes: 450)
        XCTAssertFalse(fits.contains("come off"))
        XCTAssertTrue(fits.contains("3 h of 7 h 30 m free"), fits)
    }

    func testNothingDueIsSaidPlainlyRatherThanDressedUp() {
        let out = MorningPrompt.chatOpener(dueCount: 0, totalMinutes: 0, freeMinutes: 450)
        XCTAssertTrue(out.contains("Nothing in your routine falls today"), out)
        XCTAssertTrue(out.contains("leave the day open"), "an empty day is an option, not a failure")
    }

    func testDurationReadsAsTimeNotMinutes() {
        XCTAssertEqual(MorningPrompt.duration(45), "45 min")
        XCTAssertEqual(MorningPrompt.duration(60), "1 h")
        XCTAssertEqual(MorningPrompt.duration(525), "8 h 45 m")
    }

    func testTheGymAndItsTripsComeOutOfWhatIsFree() {
        let rest = MorningPrompt.freeMinutes(gymAt: nil, gymSpanMinutes: 205)
        let gym = MorningPrompt.freeMinutes(gymAt: 17 * 60, gymSpanMinutes: 205)
        XCTAssertEqual(rest - gym, 205, "a gym day genuinely has less room, and the list should say so")
    }
}
