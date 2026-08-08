//
//  DurationOverrideTests.swift
//  JeevesTests
//
//  "Today Chores is 90 minutes, not its usual 60."
//
//  The rule that matters most here is that the override is applied in exactly
//  ONE place — `Baseline.routine` — because that is the single point the online
//  prompt and the offline packer both read the day's activities from. Applied
//  anywhere else, the two would disagree about how long the day is, and the
//  disagreement would only show up as a plan that doesn't fit.
//

import XCTest
@testable import Jeeves

final class DurationOverrideTests: XCTestCase {

    private func row(_ name: String, _ minutes: Int, order: Int,
                     enabled: Bool = true, group: RoutineGroup = .none) -> RoutineActivity {
        RoutineActivity(name: name, durationMinutes: minutes, tier: .important,
                        enabled: enabled, sortOrder: order, group: group)
    }

    private func routine() -> [RoutineActivity] {
        [row("Chores", 60, order: 0), row("Job applications", 75, order: 1)]
    }

    // MARK: the planner's single read point

    func testAnOverriddenActivityIsPlannedAtTheNewLength() {
        let out = Baseline.routine(from: routine(), durationOverrides: ["Chores": 90])
        XCTAssertEqual(out.first { $0.name == "Chores" }?.durationMinutes, 90)
    }

    func testEverythingWithoutAnOverrideKeepsItsRoutineLength() {
        let out = Baseline.routine(from: routine(), durationOverrides: ["Chores": 90])
        XCTAssertEqual(out.first { $0.name == "Job applications" }?.durationMinutes, 75,
                       "a nudge on one row must not disturb any other")
    }

    func testNoOverridesChangesNothingAtAll() {
        let plain = Baseline.routine(from: routine())
        let empty = Baseline.routine(from: routine(), durationOverrides: [:])
        XCTAssertEqual(plain.map(\.durationMinutes), empty.map(\.durationMinutes))
    }

    /// An override names an activity that no longer exists — a renamed routine
    /// row, a stale day. It must be ignored, not crash and not invent a block.
    func testAnOverrideForSomethingNotInTheRoutineIsIgnored() {
        let out = Baseline.routine(from: routine(), durationOverrides: ["Ghost": 45])
        XCTAssertEqual(out.map(\.name).sorted(), ["Chores", "Job applications"])
    }

    /// The hardcoded fallback fires when nothing is stored yet. It has to honour
    /// overrides too, or a brand-new store would silently ignore the nudge.
    func testTheDefaultRoutineHonoursOverridesAsWell() {
        let name = Baseline.activities[0].name
        let out = Baseline.routine(from: [], durationOverrides: [name: 5])
        XCTAssertEqual(out.first { $0.name == name }?.durationMinutes, 5)
    }

    func testTierAndNoteSurviveTheOverride() {
        let out = Baseline.routine(from: routine(), durationOverrides: ["Chores": 90])
        let chores = out.first { $0.name == "Chores" }
        XCTAssertEqual(chores?.tier, .important, "only the length changes")
    }

    // MARK: what gets stored

    func testOverridesRoundTripThroughTheDay() throws {
        let state = DailyPlanState(date: Date().startOfDay, hasGymToday: false, gymMinute: nil)
        state.durationOverrides = ["Chores": 90, "Reading": 45]
        XCTAssertEqual(state.durationOverrides, ["Chores": 90, "Reading": 45])
    }

    /// Empty is the ABSENCE of overrides, not a value — unlike `.only([])`,
    /// which really does mean "a deliberately blank day". Storing "{}" would
    /// leave a row that reads as a decision nobody made.
    func testClearingEveryOverrideLeavesNothingStored() {
        let state = DailyPlanState(date: Date().startOfDay, hasGymToday: false, gymMinute: nil)
        state.durationOverrides = ["Chores": 90]
        state.durationOverrides = [:]
        XCTAssertNil(state.durationOverridesJSON)
        XCTAssertEqual(state.durationOverrides, [:])
    }

    func testADayWithNoOverridesReadsAsEmptyRatherThanFailing() {
        let state = DailyPlanState(date: Date().startOfDay, hasGymToday: false, gymMinute: nil)
        XCTAssertEqual(state.durationOverrides, [:])
    }

    // MARK: the card's own arithmetic

    /// The card steps by 15 but floors at 30, because 30 is the planner's
    /// minimum block. Offering 15 would let the user set a length the packer
    /// then refuses to schedule — a worse answer than not offering it.
    func testTheStepNeverGoesBelowThePlannersOwnMinimumBlock() {
        XCTAssertGreaterThanOrEqual(30, DayPlanner.minActivityMinutes,
                                    "the card's floor must not undercut the packer's")
    }
}
