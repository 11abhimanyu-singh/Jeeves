//
//  TravelGuardTests.swift
//  JeevesTests
//
//  A trip owns its days: no stored plan may survive under a trip, and no
//  generator may create one. These tests pin the sweep (plans deleted for
//  covered days, untouched elsewhere) and the guard every generator asks.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class TravelGuardTests: XCTestCase {

    // Held so the store outlives makeContext() — a ModelContext whose
    // container has deallocated crashes on first use.
    private var container: ModelContainer!

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Trip.self, DailyPlanState.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        return container.mainContext
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func state(on date: Date, planned: Bool) -> DailyPlanState {
        let s = DailyPlanState(date: date, hasGymToday: false, gymMinute: nil)
        if planned { s.generatedPlanJSON = #"{"blocks":[]}"# }
        return s
    }

    func testIsTravelDayFollowsTripCoverage() throws {
        let context = try makeContext()
        context.insert(Trip(title: "Bali", startDate: day(2026, 9, 4), endDate: day(2026, 9, 11)))

        XCTAssertTrue(TravelGuard.isTravelDay(day(2026, 9, 4), context: context), "first day")
        XCTAssertTrue(TravelGuard.isTravelDay(day(2026, 9, 8), context: context), "middle")
        XCTAssertTrue(TravelGuard.isTravelDay(day(2026, 9, 11), context: context), "last day")
        XCTAssertFalse(TravelGuard.isTravelDay(day(2026, 9, 3), context: context), "day before")
        XCTAssertFalse(TravelGuard.isTravelDay(day(2026, 9, 12), context: context), "day after")
    }

    func testSweepDeletesPlansOnlyOnCoveredDays() async throws {
        let context = try makeContext()
        context.insert(Trip(title: "Bali", startDate: day(2026, 9, 4), endDate: day(2026, 9, 11)))
        let covered = state(on: day(2026, 9, 5), planned: true)
        let outside = state(on: day(2026, 9, 2), planned: true)
        let coveredEmpty = state(on: day(2026, 9, 6), planned: false)
        [covered, outside, coveredEmpty].forEach { context.insert($0) }

        await TravelGuard.sweep(context: context)

        XCTAssertNil(covered.generatedPlanJSON, "the trip owns its days — the stale plan goes")
        XCTAssertFalse(covered.planConfirmed)
        XCTAssertNotNil(outside.generatedPlanJSON, "ordinary days keep their plans")
        XCTAssertNil(coveredEmpty.generatedPlanJSON, "nothing to sweep stays nothing")
    }

    func testSweepWithNoTripsTouchesNothing() async throws {
        let context = try makeContext()
        let s = state(on: day(2026, 9, 5), planned: true)
        context.insert(s)
        await TravelGuard.sweep(context: context)
        XCTAssertNotNil(s.generatedPlanJSON)
    }

    func testAutoPlannerSkipsTravelDays() throws {
        let context = try makeContext()
        context.insert(Trip(title: "Bali", startDate: day(2026, 9, 4), endDate: day(2026, 9, 11)))

        // The overnight loop's day selection, filtered the way the service
        // filters it — trip-covered days must never be refilled.
        let needed = AutoPlanService.daysNeedingPlans(from: day(2026, 9, 2), days: 6, plannedDays: [])
            .filter { !TravelGuard.isTravelDay($0, context: context) }
        XCTAssertEqual(needed, [day(2026, 9, 2), day(2026, 9, 3)],
                       "only the pre-trip days survive the filter")
    }

    func testRefusalMessageNamesTheDayAndTrip() {
        let trip = Trip(title: "Bali", startDate: day(2026, 9, 4), endDate: day(2026, 9, 11))
        let msg = TravelGuard.refusalMessage(for: day(2026, 9, 5), trip: trip)
        XCTAssertTrue(msg.contains("Bali"))
        XCTAssertTrue(msg.contains("travel mode"))
    }
}
