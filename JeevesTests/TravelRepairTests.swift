//
//  TravelRepairTests.swift
//  JeevesTests
//
//  The travel-store repairs, pinned against the exact rot found on the device
//  AND the destruction modes the review caught in the first draft: launch
//  must never merge or orphan-delete (CloudKit races), boundary-day trips
//  never merge, disjoint same-hotel stays never collapse, and a timeless or
//  implausible segment must never drag a trip window.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class TravelRepairTests: XCTestCase {

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

    // MARK: Launch-safe repairs

    func testSelfTransitionsAndPhantomArrivalsDie() throws {
        let context = try makeContext()
        let trip = Trip(title: "Bali", startDate: day(2026, 9, 3), endDate: day(2026, 9, 12))
        context.insert(trip)
        let selfHop = TravelSegment(tripID: trip.id, mode: .flight, label: "Bali → Bali",
                                    fromPlace: "Karma Kandara", toPlace: "Karma Kandara",
                                    departAt: day(2026, 9, 5))
        let phantom = TravelSegment(tripID: trip.id, mode: .flight, label: "",
                                    fromPlace: "Home", toPlace: "",
                                    departAt: day(2026, 9, 3), arriveAt: day(2026, 9, 3))
        let honest = TravelSegment(tripID: trip.id, mode: .drive, label: "Drive",
                                   fromPlace: "Home", toPlace: "Lodge",
                                   arriveBy: day(2026, 9, 3), travelMinutes: 315)
        [selfHop, phantom, honest].forEach { context.insert($0) }

        TravelRepair.repairSafe(context: context)

        let segs = try context.fetch(FetchDescriptor<TravelSegment>())
        XCTAssertEqual(segs.count, 2, "the self-transition is gone")
        XCTAssertNil(phantom.arriveAt, "an arrival at departure was never real")
        XCTAssertEqual(honest.travelMinutes, 315, "healthy rows untouched")
    }

    func testLaunchSafeNeverTouchesOrphansOrOverlaps() throws {
        // The CloudKit lesson: a launch mid-sync sees half-imported data.
        // Orphans and overlapping trips must survive the automatic pass.
        let context = try makeContext()
        let a = Trip(title: "Bali", startDate: day(2026, 9, 3), endDate: day(2026, 9, 11))
        let b = Trip(title: "Bali again", startDate: day(2026, 9, 4), endDate: day(2026, 9, 11))
        [a, b].forEach { context.insert($0) }
        context.insert(TripStay(tripID: UUID(), place: "Mid-import stay",
                                arriveDate: day(2026, 9, 5), departDate: day(2026, 9, 6)))
        context.insert(TravelSegment(tripID: UUID(), mode: .drive, label: "Mid-import drive",
                                     fromPlace: "A", toPlace: "B", arriveBy: day(2026, 9, 5)))

        TravelRepair.repairSafe(context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TripStay>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TravelSegment>()).count, 1)
    }

    // MARK: Window growth

    func testWindowsGrowToCoverStays() async throws {
        // The Bandipur+Kabini case: trip ends 20 Sep, Kabini stay departs 22.
        let context = try makeContext()
        let trip = Trip(title: "Bandipur + Kabini", startDate: day(2026, 9, 18), endDate: day(2026, 9, 20))
        context.insert(trip)
        context.insert(TripStay(tripID: trip.id, place: "Bandipur",
                                arriveDate: day(2026, 9, 18), departDate: day(2026, 9, 19)))
        context.insert(TripStay(tripID: trip.id, place: "Kabini",
                                arriveDate: day(2026, 9, 20), departDate: day(2026, 9, 22)))

        await TravelRepair.repairWindows(context: context)

        XCTAssertEqual(trip.startDate, day(2026, 9, 18))
        XCTAssertEqual(trip.endDate, day(2026, 9, 22), "the trip now covers the Kabini stay")
    }

    func testWindowsNeverShrink() async throws {
        let context = try makeContext()
        let trip = Trip(title: "Wide", startDate: day(2026, 9, 1), endDate: day(2026, 9, 30))
        context.insert(trip)
        context.insert(TripStay(tripID: trip.id, place: "Somewhere",
                                arriveDate: day(2026, 9, 10), departDate: day(2026, 9, 12)))

        await TravelRepair.repairWindows(context: context)

        XCTAssertEqual(trip.startDate, day(2026, 9, 1))
        XCTAssertEqual(trip.endDate, day(2026, 9, 30))
    }

    func testTimelessAndImplausibleSegmentsCannotDragTheWindow() async throws {
        // The year-1 catastrophe from review: a timeless segment's day is
        // distantPast; unguarded min() dragged startDate to year 1 and the
        // sweep then wiped all plan history. Implausible legacy flights (a
        // road-route in the door-to-terminal slot) must not move windows
        // either.
        let context = try makeContext()
        let trip = Trip(title: "Thimphu", startDate: day(2026, 8, 12), endDate: day(2026, 8, 18))
        context.insert(trip)
        let timeless = TravelSegment(tripID: trip.id, mode: .flight, label: "No time yet")
        let implausible = TravelSegment(tripID: trip.id, mode: .flight, label: "Legacy 46h",
                                        fromPlace: "Hotel", toPlace: "Home",
                                        departAt: day(2026, 8, 18), travelMinutes: 2800)
        [timeless, implausible].forEach { context.insert($0) }

        await TravelRepair.repairWindows(context: context)

        XCTAssertEqual(trip.startDate, day(2026, 8, 12), "no year-1 start, no 2-day drag")
        XCTAssertEqual(trip.endDate, day(2026, 8, 18))
    }

    // MARK: User-invoked cleanup

    func testOverlappingTripsMergeAndAdoptTheirRows() throws {
        let context = try makeContext()
        let a = Trip(title: "Bali", startDate: day(2026, 9, 3), endDate: day(2026, 9, 11))
        let b = Trip(title: "Bali + Bali + Bali + Travel to Singapore",
                     startDate: day(2026, 9, 4), endDate: day(2026, 9, 11))
        [a, b].forEach { context.insert($0) }
        let stayA = TripStay(tripID: a.id, place: "Bali", address: "Karma Kandara",
                             arriveDate: day(2026, 9, 3), departDate: day(2026, 9, 11))
        let stayB = TripStay(tripID: b.id, place: "Bali", address: "Karma Kandara",
                             arriveDate: day(2026, 9, 4), departDate: day(2026, 9, 4))
        [stayA, stayB].forEach { context.insert($0) }
        let segB = TravelSegment(tripID: b.id, mode: .flight, label: "6E 1605",
                                 fromPlace: "Home", toPlace: "BLR",
                                 departAt: day(2026, 9, 4))
        context.insert(segB)

        let summary = TravelRepair.cleanupLegacy(context: context)

        let trips = try context.fetch(FetchDescriptor<Trip>())
        XCTAssertEqual(trips.count, 1, "genuinely overlapping trips collapse")
        XCTAssertEqual(summary.tripsMerged, 1)
        let keeper = trips[0]
        XCTAssertEqual(segB.tripID, keeper.id, "the loser's journey moved to the keeper")
        let stays = try context.fetch(FetchDescriptor<TripStay>())
        XCTAssertEqual(stays.count, 1, "the cloned overlapping stays collapse after the merge")
        XCTAssertEqual(stays[0].departDate, day(2026, 9, 11))
    }

    func testBackToBackTripsAreNeverMerged() throws {
        // Bali ends the 11th, Singapore starts the 11th — the normal
        // fly-out-on-the-last-day pattern. Sharing a boundary day is not
        // overlap; merging would destroy the user's organization.
        let context = try makeContext()
        let bali = Trip(title: "Bali", startDate: day(2026, 9, 3), endDate: day(2026, 9, 11))
        let singapore = Trip(title: "Singapore", startDate: day(2026, 9, 11), endDate: day(2026, 9, 15))
        [bali, singapore].forEach { context.insert($0) }

        let summary = TravelRepair.cleanupLegacy(context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 2)
        XCTAssertEqual(summary.tripsMerged, 0)
    }

    func testReturnToTheSameHotelStaysSeparate() throws {
        // A→B→A: two disjoint stays at the same hotel are real, not clones.
        let context = try makeContext()
        let trip = Trip(title: "Thailand", startDate: day(2026, 9, 1), endDate: day(2026, 9, 9))
        context.insert(trip)
        let bkk1 = TripStay(tripID: trip.id, place: "Bangkok", address: "Sukhumvit Hotel",
                            arriveDate: day(2026, 9, 1), departDate: day(2026, 9, 3))
        let chiangMai = TripStay(tripID: trip.id, place: "Chiang Mai", address: "Old City Inn",
                                 arriveDate: day(2026, 9, 4), departDate: day(2026, 9, 7))
        let bkk2 = TripStay(tripID: trip.id, place: "Bangkok", address: "Sukhumvit Hotel",
                            arriveDate: day(2026, 9, 8), departDate: day(2026, 9, 9))
        [bkk1, chiangMai, bkk2].forEach { context.insert($0) }

        let summary = TravelRepair.cleanupLegacy(context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<TripStay>()).count, 3,
                       "disjoint returns to the same hotel survive")
        XCTAssertEqual(summary.staysCollapsed, 0)
    }

    func testTwinIDTripsAreLeftForTheAudit() throws {
        // CloudKit can mint two rows sharing one UUID; there is no stable
        // keeper choice, so cleanup must not touch them.
        let context = try makeContext()
        let shared = UUID()
        let a = Trip(id: shared, title: "Twin", startDate: day(2026, 9, 3), endDate: day(2026, 9, 11))
        let b = Trip(id: shared, title: "Twin", startDate: day(2026, 9, 3), endDate: day(2026, 9, 11))
        [a, b].forEach { context.insert($0) }
        context.insert(TripStay(tripID: shared, place: "Somewhere",
                                arriveDate: day(2026, 9, 4), departDate: day(2026, 9, 5)))

        let summary = TravelRepair.cleanupLegacy(context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 2, "twins untouched")
        XCTAssertEqual(summary.tripsMerged, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TripStay>()).count, 1,
                       "their stay is not an orphan")
    }

    func testOrphanedRowsAreRemovedOnlyByCleanup() throws {
        let context = try makeContext()
        context.insert(Trip(title: "Real", startDate: day(2026, 9, 1), endDate: day(2026, 9, 2)))
        let ghost = UUID()
        context.insert(TripStay(tripID: ghost, place: "Nowhere",
                                arriveDate: day(2026, 9, 1), departDate: day(2026, 9, 2)))
        context.insert(TravelSegment(tripID: ghost, mode: .drive, label: "Ghost drive",
                                     arriveBy: day(2026, 9, 1)))

        let summary = TravelRepair.cleanupLegacy(context: context)

        XCTAssertEqual(summary.orphansRemoved, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TripStay>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TravelSegment>()).count, 0)
    }

    func testCloneChainCollapsesAgainstTheClusterMax() throws {
        // The device case the receipt exposed: stays 3–11, 4–4, 5–5, 7–7 under
        // one trip. Comparing against the LAST row's end let 5–5 and 7–7
        // survive ("collapsed 1" when the truth was 3) — the cluster's reach
        // is its max end.
        let context = try makeContext()
        let trip = Trip(title: "Bali", startDate: day(2026, 9, 3), endDate: day(2026, 9, 12))
        context.insert(trip)
        for (a, d) in [(3, 11), (4, 4), (5, 5), (7, 7)] {
            context.insert(TripStay(tripID: trip.id, place: "Bali", address: "Karma Kandara",
                                    arriveDate: day(2026, 9, a), departDate: day(2026, 9, d)))
        }

        let summary = TravelRepair.cleanupLegacy(context: context)

        XCTAssertEqual(summary.staysCollapsed, 3, "all three clones die in one pass")
        let stays = try context.fetch(FetchDescriptor<TripStay>())
        XCTAssertEqual(stays.count, 1)
        XCTAssertEqual(stays[0].arriveDate, day(2026, 9, 3))
        XCTAssertEqual(stays[0].departDate, day(2026, 9, 11))
    }

    func testSameTitleBoundaryTripsAreClonesAndMerge() throws {
        // "Bali" ending the 11th + "Bali" starting the 11th is the clone era,
        // not a handover — a real handover changes destination.
        let context = try makeContext()
        let a = Trip(title: "Bali", startDate: day(2026, 9, 3), endDate: day(2026, 9, 11))
        let b = Trip(title: "Bali", startDate: day(2026, 9, 11), endDate: day(2026, 9, 12))
        [a, b].forEach { context.insert($0) }

        let summary = TravelRepair.cleanupLegacy(context: context)

        XCTAssertEqual(summary.tripsMerged, 1)
        let trips = try context.fetch(FetchDescriptor<Trip>())
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips[0].startDate, day(2026, 9, 3))
        XCTAssertEqual(trips[0].endDate, day(2026, 9, 12), "union of the clones")
    }

    func testDifferentTitleBoundaryTripsStillNeverMerge() throws {
        let context = try makeContext()
        let a = Trip(title: "Bali", startDate: day(2026, 9, 3), endDate: day(2026, 9, 11))
        let b = Trip(title: "Singapore", startDate: day(2026, 9, 11), endDate: day(2026, 9, 15))
        [a, b].forEach { context.insert($0) }

        let summary = TravelRepair.cleanupLegacy(context: context)

        XCTAssertEqual(summary.tripsMerged, 0, "a real handover survives")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 2)
    }

    func testCloneJourneysCollapseToTheBestInformed() throws {
        // The falls fossil record: four outbound drives to one waterfall,
        // minted one-per-correction-turn. Same trip + mode + label + day is
        // one leg — keep the measured, latest one; cancel the losers' nudges.
        let context = try makeContext()
        let trip = Trip(title: "Shivanasamudra Falls", startDate: day(2026, 8, 2), endDate: day(2026, 8, 2))
        context.insert(trip)
        let cal = Calendar.current
        func drive(_ h: Int, _ m: Int, travel: Int) -> TravelSegment {
            TravelSegment(tripID: trip.id, mode: .drive, label: "Drive to Shivanasamudra Falls",
                          fromPlace: "Home", toPlace: "Falls",
                          arriveBy: cal.date(bySettingHour: h, minute: m, second: 0, of: day(2026, 8, 2))!,
                          checkInMinutes: 0, securityMinutes: 0, travelMinutes: travel)
        }
        let keeper = drive(12, 3, travel: 163)
        [drive(11, 0, travel: 163), drive(11, 43, travel: 163), keeper,
         drive(11, 45, travel: 0)].forEach { context.insert($0) }
        // A DIFFERENT leg on the same day must survive.
        let ret = TravelSegment(tripID: trip.id, mode: .drive, label: "Drive back home",
                                fromPlace: "Falls", toPlace: "Home",
                                arriveBy: cal.date(bySettingHour: 18, minute: 30, second: 0, of: day(2026, 8, 2))!,
                                checkInMinutes: 0, securityMinutes: 0, travelMinutes: 165)
        context.insert(ret)

        _ = TravelRepair.cleanupLegacy(context: context)

        let segs = try context.fetch(FetchDescriptor<TravelSegment>())
        XCTAssertEqual(segs.count, 2, "one outbound, one return")
        let outbound = segs.first { $0.label.contains("to Shivanasamudra") }
        XCTAssertEqual(outbound?.travelMinutes, 163)
        XCTAssertEqual(Calendar.current.component(.minute, from: outbound?.arriveBy ?? .distantPast), 3,
                       "the latest measured variant (12:03) is the keeper")
    }

    func testDisjointTripsAreLeftAlone() throws {
        let context = try makeContext()
        let a = Trip(title: "Bhadra", startDate: day(2026, 8, 15), endDate: day(2026, 8, 17))
        let b = Trip(title: "Bali", startDate: day(2026, 9, 3), endDate: day(2026, 9, 12))
        [a, b].forEach { context.insert($0) }

        let summary = TravelRepair.cleanupLegacy(context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 2)
        XCTAssertTrue(summary.isEmpty)
    }
}
