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

    // MARK: Stays written before departDate had one meaning

    /// The calendar importer used to store the last NIGHT; the ticket importer
    /// stored the day you FLY OUT. A real store held a stay whose arrive and
    /// depart were the same day, which under the new reading is nought nights.
    ///
    /// The stay that FOLLOWS settles it: if a stay ends the day before the next
    /// one begins, it was written the old way and is a day short.
    ///
    /// Every fixture here carries an externalID, because ONLY the calendar
    /// importer ever wrote the old meaning. Ticket- and chat-built stays have
    /// none, and the first version of this repair moved those too — marking a
    /// stay whose end a flight PROVES as "an end nobody can settle".
    func testAStayEndingTheDayBeforeTheNextOneIsMovedForward() {
        let trip = Trip(title: "Kabini + Bandipur", startDate: day(1), endDate: day(6))
        context.insert(trip)
        // Old-style: Kabini's end is its last NIGHT (day 2), and Bandipur
        // starts on day 3. The truth is that you are at Kabini until day 3.
        let kabini = TripStay(tripID: trip.id, place: "Kabini",
                              arriveDate: day(1), departDate: day(2), externalID: "gcal-kabini")
        let bandipur = TripStay(tripID: trip.id, place: "Bandipur",
                                arriveDate: day(3), departDate: day(6), externalID: "gcal-bandipur")
        context.insert(kabini); context.insert(bandipur)
        try? context.save()

        let receipts = applyAll()

        XCTAssertEqual(kabini.departDate, day(3), "the next stay proves the right value")
        XCTAssertEqual(kabini.nights(), 2, "nights of day 1 and day 2")
        XCTAssertTrue(receipts.contains { $0.contains("forward a day") })
    }

    /// A stay already written the new way — its end IS the next one's start —
    /// must be left alone. Moving it again would add a night that isn't there.
    func testAStayAlreadyInTheNewMeaningIsNotTouched() {
        let trip = Trip(title: "Two stops", startDate: day(1), endDate: day(6))
        context.insert(trip)
        let first = TripStay(tripID: trip.id, place: "First",
                             arriveDate: day(1), departDate: day(3))
        let second = TripStay(tripID: trip.id, place: "Second",
                              arriveDate: day(3), departDate: day(6))
        context.insert(first); context.insert(second)
        try? context.save()

        _ = applyAll()

        XCTAssertEqual(first.departDate, day(3), "unchanged")
        XCTAssertEqual(first.nights(), 2)
    }

    /// Nothing follows the last stay, so nothing can settle it. It is marked
    /// unsettled rather than guessed at, and then renders as a pair.
    func testAStayWithNothingAfterItIsMarkedUnsettledRatherThanGuessed() {
        let trip = Trip(title: "Bali", startDate: day(1), endDate: day(8))
        context.insert(trip)
        let bali = TripStay(tripID: trip.id, place: "Bali",
                            arriveDate: day(1), departDate: day(8), externalID: "gcal-bali")
        context.insert(bali)
        try? context.save()

        _ = applyAll()

        XCTAssertTrue(bali.endIsUnsettled)
        XCTAssertEqual(bali.nightsRange(), 7...8, "either reading, stated as both")
        XCTAssertEqual(bali.nightsText(), "7 or 8 nights")
    }

    /// A ticket-built stay must never be touched. SQ 510 leaves Singapore at
    /// 20:05 on the 14th, so 11–14 is settled BY A FLIGHT — and the unguarded
    /// repair flagged it as "an end nobody can settle" and marked it unsettled
    /// for ever, turning a proved fact into a permanent hedge.
    func testATicketBuiltStayIsNeverRepaired() {
        let trip = Trip(title: "Bali & Singapore", startDate: day(1), endDate: day(6))
        context.insert(trip)
        // No externalID: the ticket importer's signature.
        let singapore = TripStay(tripID: trip.id, place: "Singapore",
                                 arriveDate: day(3), departDate: day(6))
        context.insert(singapore)
        let flight = TravelSegment(tripID: trip.id, mode: .flight, label: "SQ 510",
                                   fromPlace: "SIN", toPlace: "BLR",
                                   departAt: day(6).addingTimeInterval(20 * 3600))
        context.insert(flight)
        try? context.save()

        _ = applyAll()

        XCTAssertFalse(singapore.endIsUnsettled, "the flight proves the end")
        XCTAssertEqual(singapore.departDate, day(6), "not moved")
        XCTAssertEqual(singapore.nightsText(), "3 nights", "stated, not hedged")
    }

    /// A chat-built stay is the user's own statement, and carries no
    /// externalID either. It must survive the repair untouched.
    func testAChatBuiltStayIsNeverRepaired() {
        let trip = Trip(title: "Wayanad", startDate: day(1), endDate: day(4))
        context.insert(trip)
        let stay = TripStay(tripID: trip.id, place: "Wayanad",
                            arriveDate: day(1), departDate: day(4))
        context.insert(stay)
        try? context.save()

        _ = applyAll()

        XCTAssertFalse(stay.endIsUnsettled, "the user said so")
        XCTAssertEqual(stay.departDate, day(4))
    }

    /// A stay the repair moves is also SETTLED by the move — the follower that
    /// proved the new date answers the question. Leaving the flag alone left
    /// "2 or 3 nights" standing over a date just settled.
    func testMovingAStayForwardAlsoSettlesIt() {
        let trip = Trip(title: "Kabini + Bandipur", startDate: day(1), endDate: day(6))
        context.insert(trip)
        let kabini = TripStay(tripID: trip.id, place: "Kabini",
                              arriveDate: day(1), departDate: day(2), externalID: "gcal-kabini")
        let bandipur = TripStay(tripID: trip.id, place: "Bandipur",
                                arriveDate: day(3), departDate: day(6), externalID: "gcal-bandipur")
        context.insert(kabini); context.insert(bandipur)
        try? context.save()

        _ = applyAll()

        XCTAssertFalse(kabini.endIsUnsettled, "the follower settled it")
        XCTAssertEqual(kabini.nightsText(), "2 nights")
    }

    /// The repair must be idempotent: a second pass moves nothing again.
    /// Running it twice used to be how an off-by-one became an off-by-two.
    func testTheDepartMeaningRepairIsIdempotent() {
        let trip = Trip(title: "Kabini + Bandipur", startDate: day(1), endDate: day(6))
        context.insert(trip)
        let kabini = TripStay(tripID: trip.id, place: "Kabini",
                              arriveDate: day(1), departDate: day(2), externalID: "gcal-kabini")
        let bandipur = TripStay(tripID: trip.id, place: "Bandipur",
                                arriveDate: day(3), departDate: day(6), externalID: "gcal-bandipur")
        context.insert(kabini); context.insert(bandipur)
        try? context.save()

        _ = applyAll()
        let firstEnd = kabini.departDate
        _ = applyAll()

        XCTAssertEqual(kabini.departDate, firstEnd, "a second pass must move nothing")
        XCTAssertEqual(kabini.nights(), 2)
    }
}
