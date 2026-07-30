//
//  TravelEdgeCaseTests.swift
//  JeevesTests
//
//  Judge-picked edge cases — the scenarios an author doesn't think to test
//  because they weren't the path in their head: chained back-to-back trips,
//  and a same-day handover (land from one trip, leave for the next hours
//  later). These pin the deterministic layer's behavior at the seams.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class TravelEdgeCaseTests: XCTestCase {

    private var container: ModelContainer!

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Trip.self, TripStay.self, TravelSegment.self, DailyPlanState.self, AppEvent.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        return container.mainContext
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testThreeBackToBackTripsStayThreeTrips() throws {
        // Goa ends the 5th, Hampi runs 5th-8th, Mysore starts the 8th —
        // chained boundary days, three real trips. Cleanup must merge none.
        let context = try makeContext()
        let goa = Trip(title: "Goa", startDate: day(2026, 10, 2), endDate: day(2026, 10, 5))
        let hampi = Trip(title: "Hampi", startDate: day(2026, 10, 5), endDate: day(2026, 10, 8))
        let mysore = Trip(title: "Mysore", startDate: day(2026, 10, 8), endDate: day(2026, 10, 10))
        [goa, hampi, mysore].forEach { context.insert($0) }

        let summary = TravelRepair.cleanupLegacy(context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 3)
        XCTAssertEqual(summary.tripsMerged, 0)
        // And every day 2-10 Oct is guarded by SOME trip — no seam day where
        // the planner sneaks back in.
        for d in 2...10 {
            XCTAssertTrue(TravelGuard.isTravelDay(day(2026, 10, d), context: context),
                          "Oct \(d) must be travel-guarded")
        }
        XCTAssertFalse(TravelGuard.isTravelDay(day(2026, 10, 1), context: context))
        XCTAssertFalse(TravelGuard.isTravelDay(day(2026, 10, 11), context: context))
    }

    func testSameDayHandoverBetweenTwoTrips() async throws {
        // Land home from Bhadra at 11:00; the airport run for a Bali flight
        // leaves at 17:35 the SAME day. Two trips, two journeys, one day.
        let context = try makeContext()
        let bhadra = Trip(title: "Bhadra", startDate: day(2026, 11, 6), endDate: day(2026, 11, 8))
        let bali = Trip(title: "Bali", startDate: day(2026, 11, 8), endDate: day(2026, 11, 15))
        [bhadra, bali].forEach { context.insert($0) }

        let driveHome = TravelSegment(tripID: bhadra.id, mode: .drive, label: "Drive home",
                                      fromPlace: "River Tern Lodge", toPlace: "Home",
                                      arriveBy: at(2026, 11, 8, 11, 0),
                                      checkInMinutes: 0, securityMinutes: 0,
                                      travelMinutes: 315, travelIsEstimated: false)
        let flightOut = TravelSegment(tripID: bali.id, mode: .flight, label: "6E 1605",
                                      fromPlace: "Home", toPlace: "BLR airport",
                                      departAt: at(2026, 11, 8, 21, 30),
                                      travelMinutes: 45, travelIsEstimated: false)
        [driveHome, flightOut].forEach { context.insert($0) }

        // Both journeys belong to the handover day — each shows on the 8th.
        XCTAssertEqual(driveHome.day, day(2026, 11, 8))
        XCTAssertEqual(flightOut.day, day(2026, 11, 8),
                       "leave 21:30 − 180 − 30 − 45 − 20 = 17:35, same day")

        // Absorb must not stretch either trip across the other: both
        // journeys are inside their own trip's window already.
        let movedA = await TravelGuard.absorb(driveHome, context: context)
        let movedB = await TravelGuard.absorb(flightOut, context: context)
        XCTAssertFalse(movedA)
        XCTAssertFalse(movedB)

        // The boundary day is covered, and cleanup leaves the two trips alone.
        XCTAssertTrue(TravelGuard.isTravelDay(day(2026, 11, 8), context: context))
        let summary = TravelRepair.cleanupLegacy(context: context)
        XCTAssertEqual(summary.tripsMerged, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 2)
    }

    func testJourneyGrowingOneTripToTouchAnotherNeverCausesAMerge() async throws {
        // Trip B's outbound leaves on trip A's last day (a long drive). The
        // absorb grows B back to the shared day — boundary touch — and the
        // next cleanup must STILL not merge them.
        let context = try makeContext()
        let a = Trip(title: "Coorg", startDate: day(2026, 12, 1), endDate: day(2026, 12, 4))
        let b = Trip(title: "Wayanad", startDate: day(2026, 12, 5), endDate: day(2026, 12, 9))
        [a, b].forEach { context.insert($0) }
        let longDrive = TravelSegment(tripID: b.id, mode: .drive, label: "Overnight drive",
                                      fromPlace: "Home", toPlace: "Wayanad",
                                      arriveBy: at(2026, 12, 5, 8, 0),
                                      checkInMinutes: 0, securityMinutes: 0,
                                      stopMinutes: 60, travelMinutes: 540,
                                      travelIsEstimated: false)
        context.insert(longDrive)

        // Leave = 5 Dec 08:00 − 20 − 540 − 60 = 4 Dec 21:40 → B grows to the 4th.
        let widened = await TravelGuard.absorb(longDrive, context: context)
        XCTAssertTrue(widened)
        XCTAssertEqual(b.startDate, day(2026, 12, 4))

        let summary = TravelRepair.cleanupLegacy(context: context)
        XCTAssertEqual(summary.tripsMerged, 0, "boundary touch after growth is not overlap")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 2)
    }
}
