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
        let schema = Schema([Trip.self, TripStay.self, DailyPlanState.self, TravelSegment.self, AppEvent.self])
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

    func testAbsorbGrowsTheTripToCoverAJourney() async throws {
        let context = try makeContext()
        let trip = Trip(title: "Thimphu", startDate: day(2026, 8, 12), endDate: day(2026, 8, 18))
        context.insert(trip)
        // A ~50 h outbound drive arriving 12 Aug 15:00 leaves on the 10th —
        // before the trip. Absorb must pull the start back to the leave day.
        let cal = Calendar.current
        let arrive = cal.date(bySettingHour: 15, minute: 0, second: 0, of: day(2026, 8, 12))!
        let drive = TravelSegment(tripID: trip.id, mode: .drive, label: "Drive",
                                  arriveBy: arrive, stopMinutes: 60, travelMinutes: 2950)
        context.insert(drive)

        let widened = await TravelGuard.absorb(drive, context: context)
        XCTAssertTrue(widened)
        XCTAssertEqual(trip.startDate, drive.day, "the trip now starts on the leave-by day")
        XCTAssertEqual(trip.endDate, day(2026, 8, 18), "the end is untouched")
        let again = await TravelGuard.absorb(drive, context: context)
        XCTAssertFalse(again, "idempotent once covered")
    }

    func testAbsorbIgnoresAJourneyAlreadyInsideTheWindow() async throws {
        let context = try makeContext()
        let trip = Trip(title: "Thimphu", startDate: day(2026, 8, 10), endDate: day(2026, 8, 18))
        context.insert(trip)
        let cal = Calendar.current
        let depart = cal.date(bySettingHour: 10, minute: 30, second: 0, of: day(2026, 8, 18))!
        let flight = TravelSegment(tripID: trip.id, mode: .flight, label: "KB 121",
                                   departAt: depart, travelMinutes: 90)
        context.insert(flight)

        let widened = await TravelGuard.absorb(flight, context: context)
        XCTAssertFalse(widened)
        XCTAssertEqual(trip.startDate, day(2026, 8, 10))
        XCTAssertEqual(trip.endDate, day(2026, 8, 18))
    }

    func testTripsCoveringReturnsEveryTripOnAHandoverDay() throws {
        let context = try makeContext()
        let a = Trip(title: "Bhadra", startDate: day(2026, 11, 22), endDate: day(2026, 11, 25))
        let b = Trip(title: "Kochi", startDate: day(2026, 11, 25), endDate: day(2026, 11, 28))
        [a, b].forEach { context.insert($0) }

        let covering = TravelGuard.tripsCovering(day(2026, 11, 25), context: context)
        XCTAssertEqual(covering.map(\.title), ["Bhadra", "Kochi"],
                       "both trips own the handover day, oldest first")
        XCTAssertEqual(TravelGuard.tripsCovering(day(2026, 11, 23), context: context).count, 1)
    }

    func testAbsorbStayFollowsACalendarResync() async throws {
        // The FAIL 3/10 scenario: 'Pune week' 10–12 Oct edited in Google
        // Calendar to 9–13 Oct. The stay must move and the trip must grow.
        let context = try makeContext()
        let trip = Trip(title: "Pune week", startDate: day(2026, 10, 10), endDate: day(2026, 10, 12))
        context.insert(trip)
        let stay = TripStay(tripID: trip.id, place: "Pune", address: "Hotel, Pune",
                            arriveDate: day(2026, 10, 10), departDate: day(2026, 10, 12),
                            externalID: "abc123")
        context.insert(stay)
        let planned = DailyPlanState(date: day(2026, 10, 9), hasGymToday: false, gymMinute: nil)
        planned.generatedPlanJSON = #"{"blocks":[]}"#
        context.insert(planned)

        let moved = await TravelGuard.absorbStay(externalID: "abc123",
                                                 newStart: day(2026, 10, 9),
                                                 newEnd: day(2026, 10, 13),
                                                 context: context)

        XCTAssertTrue(moved)
        XCTAssertEqual(stay.arriveDate, day(2026, 10, 9))
        XCTAssertEqual(stay.departDate, day(2026, 10, 13))
        XCTAssertEqual(trip.startDate, day(2026, 10, 9), "the trip followed the edit")
        XCTAssertEqual(trip.endDate, day(2026, 10, 13))
        XCTAssertNil(planned.generatedPlanJSON, "the newly covered day was swept")
    }

    func testAbsorbStayHealsALegacyStayWithoutExternalID() async throws {
        // The Singapore case: the stay predates externalID stamping, so a
        // calendar re-sync (event now 11–14 Sep) matched nothing and the trip
        // never grew. The fallback matches by title/venue, stamps the id, and
        // follows the edit.
        let context = try makeContext()
        let trip = Trip(title: "Bali", startDate: day(2026, 9, 3), endDate: day(2026, 9, 11))
        context.insert(trip)
        let stay = TripStay(tripID: trip.id, place: "Travel to Singapore", address: "Singapore",
                            arriveDate: day(2026, 9, 11), departDate: day(2026, 9, 11))
        context.insert(stay)

        let moved = await TravelGuard.absorbStay(externalID: "goog-sing-1",
                                                 title: "Travel to Singapore", address: "Singapore",
                                                 newStart: day(2026, 9, 11), newEnd: day(2026, 9, 14),
                                                 context: context)

        XCTAssertTrue(moved)
        XCTAssertEqual(stay.externalID, "goog-sing-1", "the row is healed for next time")
        XCTAssertEqual(stay.departDate, day(2026, 9, 14))
        XCTAssertEqual(trip.endDate, day(2026, 9, 14), "12–14 Sep are travel days now")
    }

    func testAbsorbStayNeverShrinksTheTrip() async throws {
        let context = try makeContext()
        let trip = Trip(title: "Pune week", startDate: day(2026, 10, 9), endDate: day(2026, 10, 13))
        context.insert(trip)
        context.insert(TripStay(tripID: trip.id, place: "Pune",
                                arriveDate: day(2026, 10, 9), departDate: day(2026, 10, 13),
                                externalID: "abc123"))

        _ = await TravelGuard.absorbStay(externalID: "abc123",
                                         newStart: day(2026, 10, 10), newEnd: day(2026, 10, 11),
                                         context: context)

        XCTAssertEqual(trip.startDate, day(2026, 10, 9), "shrinking stays a deliberate act")
        XCTAssertEqual(trip.endDate, day(2026, 10, 13))
    }

    func testFlightJourneyPlausibilityRule() {
        XCTAssertTrue(LeaveBy.plausibleFlightJourney(90))
        XCTAssertTrue(LeaveBy.plausibleFlightJourney(360))
        XCTAssertFalse(LeaveBy.plausibleFlightJourney(361))
        XCTAssertFalse(LeaveBy.plausibleFlightJourney(2400), "the 40 h road route stays refused")
    }

    func testRefusalMessageNamesTheDayAndTrip() {
        let trip = Trip(title: "Bali", startDate: day(2026, 9, 4), endDate: day(2026, 9, 11))
        let msg = TravelGuard.refusalMessage(for: day(2026, 9, 5), trip: trip)
        XCTAssertTrue(msg.contains("Bali"))
        XCTAssertTrue(msg.contains("travel mode"))
    }
}
