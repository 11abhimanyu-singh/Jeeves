//
//  DataRepairTests.swift
//  JeevesTests
//
//  Built against the ACTUAL rows in the 1 Aug store, not invented shapes:
//  three identical Shivanasamudra trips, four copies of one drive, two Bali
//  stays sitting inside a longer Bali stay, a Bhadra event stored as a span
//  AND as day rows, a check-in with leftover cardio, plans with "31:00", and
//  three books on one ISBN.
//
//  The dividing line these pin: a rule may collapse an exact duplicate, but
//  never decide which of three disagreeing books is the real one.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class DataRepairTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() {
        super.setUp()
        let schema = Schema([Trip.self, TripStay.self, TravelSegment.self, DailyEvent.self,
                             CheckIn.self, DailyPlanState.self, Book.self, ReadingLog.self,
                             AppEvent.self, CalendarTombstone.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        container = try! ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() { container = nil; super.tearDown() }

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date())!.startOfDay
    }

    private func applyAll() -> [String] {
        let findings = DataRepair.scan(context: context)
        return DataRepair.applyAll(findings, context: context)
    }

    // MARK: Trips

    func testIdenticalTripsCollapseAndKeepTheirChildren() {
        // Three "Shivanasamudra Falls" trips on one day, as found in the store.
        let a = Trip(title: "Shivanasamudra Falls", startDate: day(1), endDate: day(1))
        let b = Trip(title: "Shivanasamudra Falls", startDate: day(1), endDate: day(1))
        context.insert(a); context.insert(b)
        context.insert(TravelSegment(tripID: b.id, mode: .drive, label: "Drive back home",
                                     arriveBy: day(1).addingTimeInterval(64_800)))
        try? context.save()

        _ = applyAll()

        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        let segs = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
        XCTAssertEqual(trips.count, 1, "identical trips collapse to one")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.tripID, trips.first?.id,
                       "the survivor adopts the loser's journey — no orphan")
    }

    func testADoubledTitleIsRenamedButAWeldedOneIsLeftForTheUser() {
        let doubled = Trip(title: "Bhadra Tiger Reserve -Tour + Bhadra Tiger Reserve -Tour",
                           startDate: day(14), endDate: day(16))
        let welded = Trip(title: "Arvind- Photography tour- Bandipur + Arvind Photography Tour- Kabini",
                          startDate: day(47), endDate: day(51))
        context.insert(doubled); context.insert(welded)
        try? context.save()

        let findings = DataRepair.scan(context: context)
        _ = DataRepair.applyAll(findings, context: context)

        XCTAssertEqual(doubled.title, "Bhadra Tiger Reserve -Tour",
                       "the same name joined to itself is just mangled — safe to repair")
        XCTAssertTrue(welded.title.contains(" + "),
                      "two DIFFERENT trips welded together needs the user, not a guess")
        XCTAssertTrue(findings.contains { $0.action == .manual && $0.title.contains("welded") })
    }

    // MARK: Stays and journeys

    func testStaysInsideALongerStayAreRemoved() {
        let trip = Trip(title: "Bali", startDate: day(30), endDate: day(38))
        context.insert(trip)
        context.insert(TripStay(tripID: trip.id, place: "Bali", arriveDate: day(30), departDate: day(38)))
        context.insert(TripStay(tripID: trip.id, place: "Bali", arriveDate: day(32), departDate: day(32)))
        context.insert(TripStay(tripID: trip.id, place: "Bali", arriveDate: day(34), departDate: day(34)))
        try? context.save()

        _ = applyAll()

        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        XCTAssertEqual(stays.count, 1, "the two single days were already inside the long booking")
        XCTAssertEqual(stays.first?.arriveDate, day(30))
    }

    func testDuplicateJourneysCollapseKeepingTheMeasuredOne() {
        let trip = Trip(title: "Falls", startDate: day(2), endDate: day(2))
        context.insert(trip)
        let anchor = day(2).addingTimeInterval(50_000)
        for minutes in [163, 163, 0, 165] {
            context.insert(TravelSegment(tripID: trip.id, mode: .drive,
                                         label: "Drive to Shivanasamudra Falls",
                                         toPlace: "Shivanasamudra", arriveBy: anchor,
                                         travelMinutes: minutes))
        }
        try? context.save()

        _ = applyAll()

        let segs = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.travelMinutes, 165,
                       "the measured copy survives, not the 0-minute one")
    }

    // MARK: Events

    func testDayRowsInsideAMultiDayEventAreRemovedAndTombstoned() {
        context.insert(DailyEvent(date: day(13), title: "Bhadra Tiger Reserve -Tour",
                                  startMinute: 0, endMinute: 0, isAllDay: true,
                                  spanEndDate: day(15), externalID: "gcal-bhadra"))
        context.insert(DailyEvent(date: day(14), title: "Bhadra Tiger Reserve -Tour",
                                  startMinute: 0, endMinute: 0, isAllDay: true,
                                  externalID: "gcal-bhadra-2"))
        context.insert(DailyEvent(date: day(15), title: "Bhadra Tiger Reserve -Tour",
                                  startMinute: 0, endMinute: 0, isAllDay: true,
                                  externalID: "gcal-bhadra-3"))
        try? context.save()

        _ = applyAll()

        let events = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        XCTAssertEqual(events.count, 1, "the span already covers those days")
        XCTAssertNotNil(events.first?.spanEndDate, "and it's the span that survives")
        XCTAssertEqual(CalendarTombstone.ids(in: context).count, 2,
                       "tombstoned, or the next sync puts them straight back")
    }

    // MARK: Check-ins, plans, books

    func testLeftoverCardioDetailsAreCleared() {
        let c = CheckIn(date: day(-6), workedOut: true, weightTraining: true,
                        stretching: false, mobility: false, cardio: false,
                        cardioType: "Inclined Walk", cardioDuration: nil, cardioIncline: nil)
        context.insert(c)
        try? context.save()

        _ = applyAll()

        XCTAssertNil(c.cardioType, "no cardio means no cardio descriptor")
    }

    func testPlanClockPastMidnightIsRepairedAndZeroLengthBlocksDropped() throws {
        let plan = GeneratedPlan(
            blocks: [
                GeneratedBlock(title: "Sleep", startTime: "23:00", endTime: "31:00",
                               note: nil, isAnchor: false, kind: "sleep"),
                GeneratedBlock(title: "Commute Mysore → Home", startTime: "22:00", endTime: "22:00",
                               note: nil, isAnchor: false, kind: "commute"),
                GeneratedBlock(title: "Reading", startTime: "20:00", endTime: "21:00",
                               note: nil, isAnchor: false, kind: "activity"),
            ],
            dropped: [], shrunk: [], summary: "test", boundaryTime: nil)
        let state = DailyPlanState(date: day(-10), hasGymToday: false, gymMinute: nil)
        state.generatedPlanJSON = String(data: try JSONEncoder().encode(plan), encoding: .utf8)
        context.insert(state)
        try? context.save()

        _ = applyAll()

        let json = try XCTUnwrap(state.generatedPlanJSON)
        let repaired = try JSONDecoder().decode(GeneratedPlan.self,
                                                from: Data(json.utf8))
        XCTAssertEqual(repaired.blocks.count, 2, "the zero-length commute is gone")
        XCTAssertFalse(repaired.blocks.contains { $0.endTime == "31:00" },
                       "and no clock reads past the end of the day")
        XCTAssertTrue(repaired.blocks.contains { $0.title == "Reading" },
                      "healthy blocks survive untouched")
    }

    func testSharedISBNIsReportedNotResolved() {
        for title in ["National Geographic Greatest Landscapes",
                      "Greatest Landscapes: Stunning Photographs",
                      "Greatest landscapes"] {
            let b = Book(title: title, author: "National Geographic", isFiction: false)
            b.isbn = "9781426217128"
            context.insert(b)
        }
        try? context.save()

        let findings = DataRepair.scan(context: context)
        _ = DataRepair.applyAll(findings, context: context)

        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        XCTAssertEqual(books.count, 3, "which one is real is the user's call — nothing deleted")
        XCTAssertTrue(findings.contains { $0.action == .manual && $0.title.contains("ISBN") })
    }

    func testMissingFictionFlagIsFilledIn() {
        let b = Book(title: "Greatest landscapes", author: "National Geographic",
                     isFiction: nil)
        context.insert(b)
        try? context.save()

        _ = applyAll()

        XCTAssertEqual(b.isFiction, false)
    }

    // MARK: The whole pass

    func testACleanStoreReportsNothing() {
        XCTAssertTrue(DataRepair.scan(context: context).isEmpty)
    }

    func testEveryRepairIsLogged() {
        let a = Trip(title: "Falls", startDate: day(1), endDate: day(1))
        let b = Trip(title: "Falls", startDate: day(1), endDate: day(1))
        context.insert(a); context.insert(b)
        try? context.save()

        let receipts = applyAll()

        XCTAssertFalse(receipts.isEmpty)
        let logged = ((try? context.fetch(FetchDescriptor<AppEvent>())) ?? [])
            .filter { $0.detail.contains("data repair") }
        XCTAssertEqual(logged.count, receipts.count,
                       "a repair that isn't logged is a repair that hid an anomaly")
    }

    func testRunningTwiceIsSafe() {
        let a = Trip(title: "Falls", startDate: day(1), endDate: day(1))
        let b = Trip(title: "Falls", startDate: day(1), endDate: day(1))
        context.insert(a); context.insert(b)
        try? context.save()

        _ = applyAll()
        let second = applyAll()

        XCTAssertTrue(second.isEmpty, "nothing left to do the second time")
        XCTAssertEqual(((try? context.fetch(FetchDescriptor<Trip>())) ?? []).count, 1)
    }
}
