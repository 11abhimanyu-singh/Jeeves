//
//  RoutineCatalogTests.swift
//  JeevesTests
//
//  The routine → prompt conversion is pure, so it's unit-testable without a
//  store: enabled activities in fill order, with a safe fallback to the
//  hardcoded default when nothing's been set up yet.
//

import XCTest
@testable import Jeeves

final class RoutineCatalogTests: XCTestCase {

    func testEmptyRoutineFallsBackToDefault() {
        let result = Baseline.routine(from: [])
        XCTAssertEqual(result.map(\.name), Baseline.activities.map(\.name),
                       "an unseeded store must plan with the default routine")
    }

    func testDisabledActivitiesAreExcluded() {
        let acts = [
            RoutineActivity(name: "Reading", durationMinutes: 90, tier: .important, enabled: true, sortOrder: 0),
            RoutineActivity(name: "Photography", durationMinutes: 30, tier: .flexible, enabled: false, sortOrder: 1),
            RoutineActivity(name: "Chores", durationMinutes: 40, tier: .flexible, enabled: true, sortOrder: 2),
        ]
        let result = Baseline.routine(from: acts)
        XCTAssertEqual(result.map(\.name), ["Reading", "Chores"], "a disabled activity must be skipped")
    }

    func testResultIsInFillOrder() {
        let acts = [
            RoutineActivity(name: "C", durationMinutes: 30, tier: .flexible, enabled: true, sortOrder: 2),
            RoutineActivity(name: "A", durationMinutes: 30, tier: .flexible, enabled: true, sortOrder: 0),
            RoutineActivity(name: "B", durationMinutes: 30, tier: .flexible, enabled: true, sortOrder: 1),
        ]
        XCTAssertEqual(Baseline.routine(from: acts).map(\.name), ["A", "B", "C"])
    }

    func testAllDisabledFallsBackToDefault() {
        let acts = [RoutineActivity(name: "X", durationMinutes: 30, tier: .flexible, enabled: false, sortOrder: 0)]
        XCTAssertEqual(Baseline.routine(from: acts).map(\.name), Baseline.activities.map(\.name),
                       "if the user disables everything, plan with the default rather than an empty day")
    }

    // MARK: cadence

    /// 3 Aug 2026 is a Monday (weekday 2); 4 Aug is a Tuesday (weekday 3).
    private func aug(_ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: d))!
    }

    private func withCadence(_ name: String, _ weekdays: Set<Int>, order: Int) -> RoutineActivity {
        let a = RoutineActivity(name: name, durationMinutes: 30, tier: .flexible, enabled: true, sortOrder: order)
        a.cadence = Cadence(weekdays: weekdays)
        return a
    }

    func testAnActivityIsSkippedOnADayItsCadenceExcludes() {
        let acts = [
            withCadence("Photography", [7], order: 0),   // Saturdays
            withCadence("Reading", [], order: 1),        // every day
        ]
        XCTAssertEqual(Baseline.routine(from: acts, on: aug(4)).map(\.name), ["Reading"],
                       "Tuesday is not Saturday, so Photography is not today's problem")
    }

    /// The decision this whole precedence question turned on. The weekday chips
    /// set a day's default shape; opening the picker and ticking something is
    /// the user overriding that shape for today. Dropping what they ticked would
    /// be the same dishonesty as the invented filler this work removes.
    ///
    /// Deliberately the OPPOSITE of `enabled`, which outranks a tick — see
    /// ActivitySelectionTests.testASwitchedOffRoutineRowStaysOffEvenIfTicked.
    /// "I don't do this at all" and "not usually today" are different claims.
    func testATickedActivityPlansEvenWhenItsCadenceExcludesTheDay() {
        let acts = [withCadence("Photography", [7], order: 0)]
        let out = Baseline.routine(from: acts, selection: .only(["Photography"]), on: aug(4))
        XCTAssertEqual(out.map(\.name), ["Photography"],
                       "a deliberate tick on a Tuesday beats a Saturday cadence")
    }

    /// The landmine. Before this, an empty *result* fell back to the eight
    /// hardcoded defaults — so a Sunday the cadence had legitimately left light
    /// came back carrying a full day's work, refilling exactly what the feature
    /// exists to prevent. The fallback now keys on the ROUTINE being empty.
    func testACadenceLightDayStaysLightInsteadOfBeingRefilled() {
        let acts = [
            withCadence("Chores", [2], order: 0),   // Mondays
            withCadence("Reading", [2], order: 1),  // Mondays
        ]
        XCTAssertTrue(Baseline.routine(from: acts, on: aug(4)).isEmpty,
                      "nothing is due on Tuesday, and nothing is what the day should contain")
    }

    /// `isPlanned` is the single rule both the planner filter and chat's
    /// `planned_today` read. Testing it directly is what stops the two drifting
    /// into chat saying an activity is on today while the planner drops it.
    func testIsPlannedIsTheOneRuleBothThePlannerAndChatAsk() {
        let a = withCadence("Photography", [7], order: 0)   // Saturdays

        XCTAssertFalse(a.isPlanned(on: aug(4)), "Tuesday is not one of its days")
        XCTAssertTrue(a.isPlanned(on: aug(8)), "Saturday is")
        XCTAssertTrue(a.isPlanned(on: aug(4), selection: .only(["Photography"])),
                      "an explicit tick outranks the cadence")
        XCTAssertTrue(a.isPlanned(on: nil), "no day in hand must never lose an activity")

        a.enabled = false
        XCTAssertFalse(a.isPlanned(on: aug(8)), "the switch outranks the cadence")
        XCTAssertFalse(a.isPlanned(on: aug(4), selection: .only(["Photography"])),
                       "and it outranks an explicit tick too — that rule is unchanged")
    }

    func testWithoutADateCadenceIsNotConsultedAtAll() {
        let acts = [withCadence("Photography", [7], order: 0)]
        XCTAssertEqual(Baseline.routine(from: acts).map(\.name), ["Photography"],
                       "callers with no day in hand must not silently lose activities")
    }

    func testDurationAndTierCarryThrough() {
        let acts = [RoutineActivity(name: "Deep work", durationMinutes: 120, tier: .mustDo, enabled: true, sortOrder: 0)]
        let b = Baseline.routine(from: acts).first
        XCTAssertEqual(b?.durationMinutes, 120)
        XCTAssertEqual(b?.tier, .mustDo)
    }
}
