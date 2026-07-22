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

    func testDurationAndTierCarryThrough() {
        let acts = [RoutineActivity(name: "Deep work", durationMinutes: 120, tier: .mustDo, enabled: true, sortOrder: 0)]
        let b = Baseline.routine(from: acts).first
        XCTAssertEqual(b?.durationMinutes, 120)
        XCTAssertEqual(b?.tier, .mustDo)
    }
}
