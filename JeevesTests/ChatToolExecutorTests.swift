//
//  ChatToolExecutorTests.swift
//  JeevesTests
//
//  Pins the trajectory-eval fixes at the executor level, offline:
//  - add_stay creates the trip a new itinerary needs instead of dumping the
//    stay into whatever trip exists (the merged-Mysore bug, t1-5/t1-8)
//  - delete_stay previews before deleting (t1-9)
//  - add_journey refuses to guess a missing date (the 31-Jul leave-by bug)
//  - a deleted synced event is tombstoned so calendar sync can't resurrect
//    it (the Bhadra bug from the real-log eval)
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class ChatToolExecutorTests: XCTestCase {

    private var container: ModelContainer!
    private var executor: ChatToolExecutor!

    override func setUp() {
        super.setUp()
        let schema = Schema([
            Trip.self, TravelSegment.self, TripStay.self, DailyEvent.self,
            SavedLocation.self, AppEvent.self, CalendarTombstone.self,
            DailyPlanState.self, ChatTurn.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        container = try! ModelContainer(for: schema, configurations: [config])
        executor = ChatToolExecutor(modelContext: container.mainContext)
        executor.commuteMinutes = { _, _, _ in 42 }
        executor.scheduleNudges = false
    }

    override func tearDown() {
        executor = nil
        container = nil
        super.tearDown()
    }

    private func day(_ offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: add_stay trip resolution

    func testAddStayCreatesNamedTripInsteadOfAttachingToUnrelatedOne() async {
        let context = container.mainContext
        // A Singapore trip exists and does NOT cover the stay's dates.
        context.insert(Trip(title: "Singapore",
                            startDate: Date().startOfDay,
                            endDate: Calendar.current.date(byAdding: .day, value: 3, to: Date())!.startOfDay))
        try? context.save()

        let result = await executor.run(.init(
            id: "t1", name: "add_stay",
            input: ["trip": "Mysore", "hotel": "Radisson Mysore",
                    "arrive_date": day(10), "depart_date": day(12)]))

        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        XCTAssertEqual(trips.count, 2, "the stay must CREATE the Mysore trip")
        let mysore = trips.first { $0.title == "Mysore" }
        XCTAssertNotNil(mysore)
        XCTAssertEqual(stays.count, 1)
        XCTAssertEqual(stays.first?.tripID, mysore?.id,
                       "stay belongs to the NEW trip, never the Singapore one")
        XCTAssertTrue(result.text.contains("NEW trip"), "receipt must say a trip was created")
    }

    func testAddStayJoinsCoveringTripWhenNoNameGiven() async {
        let context = container.mainContext
        let trip = Trip(title: "Coorg",
                        startDate: Calendar.current.date(byAdding: .day, value: 5, to: Date())!.startOfDay,
                        endDate: Calendar.current.date(byAdding: .day, value: 9, to: Date())!.startOfDay)
        context.insert(trip)
        try? context.save()

        _ = await executor.run(.init(
            id: "t2", name: "add_stay",
            input: ["trip": "", "hotel": "Evolve Back",
                    "arrive_date": day(6), "depart_date": day(8)]))

        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        XCTAssertEqual(trips.count, 1, "covered dates + no name → join the covering trip")
        XCTAssertEqual(stays.first?.tripID, trip.id)
    }

    func testAddStayIsIdempotentForTheSameBooking() async {
        let context = container.mainContext
        for id in ["s1", "s2"] {
            _ = await executor.run(.init(
                id: id, name: "add_stay",
                input: ["trip": "Ooty", "hotel": "Western Valley Resort",
                        "arrive_date": day(14), "depart_date": day(16)]))
        }
        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        XCTAssertEqual(stays.count, 1, "the same booking twice must UPDATE, not duplicate")
    }

    func testSameHotelOnSeparateDatesStaysTwoBookings() async {
        let context = container.mainContext
        _ = await executor.run(.init(
            id: "s3", name: "add_stay",
            input: ["trip": "Delhi", "hotel": "Airport Hotel",
                    "arrive_date": day(5), "depart_date": day(6)]))
        _ = await executor.run(.init(
            id: "s4", name: "add_stay",
            input: ["trip": "Delhi", "hotel": "Airport Hotel",
                    "arrive_date": day(12), "depart_date": day(13)]))
        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        XCTAssertEqual(stays.count, 2, "first and last night at the same hotel are two bookings")
    }

    // MARK: add_stay continues an open itinerary (t1-8, t1-13)

    /// "From Mysore I drive to Wayanad and stay at CGH Earth" — the stay runs
    /// past the Mysore trip's end so nothing COVERS it, and the executor used
    /// to mint a second trip beside the one the user was already on.
    /// add_stay measures its auto transition on a background Task. Let it land
    /// before the container goes away, or the teardown pulls the store out from
    /// under a live model instance and the whole test process dies.
    private func drainBackgroundMeasure() async {
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let segs = (try? container.mainContext.fetch(FetchDescriptor<TravelSegment>())) ?? []
            if segs.contains(where: { $0.travelMinutes > 0 }) { return }
        }
    }

    func testAddStayContinuesTheOpenTripItRunsPast() async {
        let context = container.mainContext
        let start = Calendar.current.date(byAdding: .day, value: 5, to: Date())!.startOfDay
        let end = Calendar.current.date(byAdding: .day, value: 7, to: Date())!.startOfDay
        let trip = Trip(title: "Mysore", startDate: start, endDate: end)
        context.insert(trip)
        context.insert(TripStay(tripID: trip.id, place: "Radisson Blu Mysore",
                                arriveDate: start, departDate: end))
        // The only journey so far took them OUT — nothing has brought them home.
        context.insert(TravelSegment(tripID: trip.id, mode: .drive, label: "Home → Mysore",
                                     toPlace: "Radisson Mysore",
                                     arriveBy: start.addingTimeInterval(14 * 3600)))
        try? context.save()

        _ = await executor.run(.init(
            id: "c1", name: "add_stay",
            input: ["trip": "", "hotel": "CGH Earth Wayanad",
                    "arrive_date": day(7), "depart_date": day(10)]))

        await drainBackgroundMeasure()
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        XCTAssertEqual(trips.count, 1, "the itinerary continues — no second trip")
        XCTAssertEqual(stays.count, 2)
        XCTAssertEqual(stays.first { $0.place.contains("CGH") }?.tripID, trip.id)
        XCTAssertEqual(trips.first?.endDate,
                       Calendar.current.date(byAdding: .day, value: 10, to: Date())!.startOfDay,
                       "the trip window grows to cover the new stay")
    }

    /// The counterweight: once a leg has landed them back home the trip is
    /// closed, and the next morning's drive starts a NEW trip. This is the
    /// merged-Mysore bug (t1-5) — the two must not become one.
    func testAddStayStartsANewTripOnceTheLastLegLandedHome() async {
        let context = container.mainContext
        let start = Date().startOfDay
        let end = Calendar.current.date(byAdding: .day, value: 5, to: Date())!.startOfDay
        let trip = Trip(title: "Singapore", startDate: start, endDate: end)
        context.insert(trip)
        context.insert(TripStay(tripID: trip.id, place: "Singapore",
                                arriveDate: start, departDate: end))
        context.insert(TravelSegment(tripID: trip.id, mode: .flight, label: "SQ 510",
                                     fromPlace: "Singapore", toPlace: "BLR",
                                     departAt: end.addingTimeInterval(19 * 3600 + 40 * 60)))
        try? context.save()

        _ = await executor.run(.init(
            id: "c2", name: "add_stay",
            input: ["trip": "", "hotel": "Radisson Blu Mysore",
                    "arrive_date": day(6), "depart_date": day(8)]))

        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        XCTAssertEqual(trips.count, 2, "they came home — Mysore is its own trip")
        XCTAssertEqual(trips.first { $0.title == "Singapore" }?.endDate, end,
                       "the Singapore window must not stretch over the Mysore days")
    }

    /// The same mistake wearing a label: the model naming the trip after the
    /// hotel. It still belongs to the open itinerary, and the receipt has to
    /// say which trip it actually joined rather than silently overruling.
    func testStayUnderAnInventedTripNameStillContinuesTheOpenTrip() async {
        let context = container.mainContext
        let start = Calendar.current.date(byAdding: .day, value: 5, to: Date())!.startOfDay
        let end = Calendar.current.date(byAdding: .day, value: 7, to: Date())!.startOfDay
        let trip = Trip(title: "Mysore", startDate: start, endDate: end)
        context.insert(trip)
        context.insert(TripStay(tripID: trip.id, place: "Radisson Blu Mysore",
                                arriveDate: start, departDate: end))
        context.insert(TravelSegment(tripID: trip.id, mode: .drive, label: "Home → Mysore",
                                     toPlace: "Radisson Mysore",
                                     arriveBy: start.addingTimeInterval(14 * 3600)))
        try? context.save()

        let out = await executor.run(.init(
            id: "c3", name: "add_stay",
            input: ["trip": "CGH Earth Wayanad", "hotel": "CGH Earth Wayanad",
                    "arrive_date": day(7), "depart_date": day(10)]))

        await drainBackgroundMeasure()
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        XCTAssertEqual(trips.count, 1, "an invented trip name must not fork the itinerary")
        XCTAssertTrue(out.text.contains("Mysore"), "the receipt names the trip it really joined")
    }

    func testPlaceWordMatchIgnoresFillerAndShortTokens() {
        XCTAssertTrue(ChatToolExecutor.sharesPlaceWord("Radisson hotel Mysore",
                                                       "Radisson Blu Mysore, Nazarbad"))
        XCTAssertFalse(ChatToolExecutor.sharesPlaceWord("Singapore", "BLR"))
        // "hotel" alone is not a match.
        XCTAssertFalse(ChatToolExecutor.sharesPlaceWord("Airport hotel", "The hotel"))
    }

    // MARK: chat can READ travel, not only write it (t1-12)

    func testFetchAppDataServesJourneysTripsAndStays() async throws {
        let context = container.mainContext
        let start = Calendar.current.date(byAdding: .day, value: 3, to: Date())!.startOfDay
        let end = Calendar.current.date(byAdding: .day, value: 6, to: Date())!.startOfDay
        let trip = Trip(title: "Wayanad", startDate: start, endDate: end)
        context.insert(trip)
        context.insert(TripStay(tripID: trip.id, place: "CGH Earth Wayanad",
                                arriveDate: start, departDate: end))
        context.insert(TravelSegment(tripID: trip.id, mode: .drive, label: "Home → Wayanad",
                                     toPlace: "CGH Earth Wayanad",
                                     arriveBy: start.addingTimeInterval(14 * 3600),
                                     travelMinutes: 260, travelIsEstimated: false))
        try? context.save()

        func rows(_ collection: String, _ extra: [String: Any] = [:]) async throws -> [[String: Any]] {
            var input: [String: Any] = ["collection": collection]
            extra.forEach { input[$0] = $1 }
            let out = await executor.run(.init(id: "f", name: "fetch_app_data", input: input))
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.text.utf8)) as? [String: Any])
            return try XCTUnwrap(obj["rows"] as? [[String: Any]])
        }

        let trips = try await rows("trips")
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?["title"] as? String, "Wayanad")
        XCTAssertEqual((trips.first?["stays"] as? [String])?.first, "CGH Earth Wayanad")

        let journeys = try await rows("journeys")
        XCTAssertEqual(journeys.count, 1, "a journey question is answered from journeys")
        XCTAssertEqual(journeys.first?["travelMinutes"] as? String, "260")

        let stays = try await rows("stays")
        XCTAssertEqual(stays.first?["trip"] as? String, "Wayanad")

        // A window narrows it, so "anything in August" is one call.
        let after = try await rows("journeys", ["from": day(20)])
        XCTAssertTrue(after.isEmpty, "the drive is before the window")
        let around = try await rows("journeys", ["from": day(0), "to": day(30)])
        XCTAssertEqual(around.count, 1)
    }

    func testUnmeasuredJourneyReportsNotMeasuredRatherThanZero() async throws {
        let context = container.mainContext
        let trip = Trip(title: "Ooty", startDate: Date().startOfDay,
                        endDate: Calendar.current.date(byAdding: .day, value: 2, to: Date())!.startOfDay)
        context.insert(trip)
        context.insert(TravelSegment(tripID: trip.id, mode: .drive, label: "Home → Ooty",
                                     toPlace: "Ooty", arriveBy: Date().startOfDay.addingTimeInterval(50_000)))
        try? context.save()

        let out = await executor.run(.init(id: "f2", name: "fetch_app_data",
                                           input: ["collection": "journeys"]))
        XCTAssertTrue(out.text.contains("not measured"),
                      "an unmeasured leg must not read as a confident 0 minutes")
    }

    func testStateNoteNamesTravelOnFile() async {
        let context = container.mainContext
        XCTAssertTrue(executor.stateNote().contains("No trips or journeys stored"))
        let trip = Trip(title: "Waterfall day", startDate: Date().startOfDay,
                        endDate: Date().startOfDay)
        context.insert(trip)
        try? context.save()
        XCTAssertTrue(executor.stateNote().contains("Waterfall day"),
                      "chat said 'no journey planned' on a morning a trip was on file")
    }

    // MARK: days are days (t1-9, t1-11)

    func testShiftByDaysMovesTheWholeEventAndItsSpan() async {
        let context = container.mainContext
        _ = await executor.run(.init(
            id: "e1", name: "add_event",
            input: ["title": "Dinner with Arvind", "date": day(1),
                    "start_time": "20:00", "end_time": "22:00"]))
        _ = await executor.run(.init(
            id: "e2", name: "edit_event",
            input: ["title": "Dinner with Arvind", "shift_by_days": 1]))

        let events = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        XCTAssertEqual(events.count, 1, "postponing must move the event, never re-create it")
        let moved = events.first
        XCTAssertEqual(moved?.date,
                       Calendar.current.date(byAdding: .day, value: 2, to: Date())!.startOfDay)
        XCTAssertEqual(moved?.startMinute, 20 * 60, "the time of day is preserved")
        XCTAssertEqual(moved?.endMinute, 22 * 60)

        // And back two days — "prepone" is the same tool with a negative shift.
        _ = await executor.run(.init(
            id: "e3", name: "edit_event",
            input: ["title": "Dinner with Arvind", "shift_by_days": -2]))
        let after = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.date, Date().startOfDay)
    }

    // MARK: stale travel data after an edit

    func testMovingAStayReAnchorsAndReMeasuresItsDrives() async throws {
        let context = container.mainContext
        _ = await executor.run(.init(
            id: "v1", name: "add_stay",
            input: ["trip": "Mysore", "hotel": "Radisson Mysore",
                    "arrive_date": day(10), "depart_date": day(12)]))
        _ = await executor.run(.init(
            id: "v2", name: "add_stay",
            input: ["trip": "Mysore", "hotel": "CGH Earth Wayanad",
                    "arrive_date": day(12), "depart_date": day(14)]))

        // Wait for the background measure so there is a drive to re-anchor.
        var seg: TravelSegment?
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let segs = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
            if let s = segs.first(where: { $0.travelMinutes > 0 }) { seg = s; break }
        }
        let before = try XCTUnwrap(seg?.arriveBy)

        let result = await executor.run(.init(
            id: "v3", name: "update_stay",
            input: ["hotel": "CGH Earth Wayanad", "new_arrive_date": day(13),
                    "new_depart_date": day(15)]))

        let after = try XCTUnwrap(seg?.arriveBy)
        XCTAssertGreaterThan(after, before,
                             "the drive INTO the stay must follow it to the new day")
        XCTAssertTrue(result.text.contains("Re-measured"),
                      "the receipt must name what moved with it: \(result.text)")
    }

    func testMovingAStayNeverRewritesAFlightsDeparture() async {
        let context = container.mainContext
        let trip = Trip(title: "Bali", startDate: Date().startOfDay,
                        endDate: Calendar.current.date(byAdding: .day, value: 8, to: Date())!.startOfDay)
        context.insert(trip)
        let stay = TripStay(tripID: trip.id, place: "Karma Kandara",
                            address: "Karma Kandara, Uluwatu",
                            arriveDate: Date().startOfDay,
                            departDate: Calendar.current.date(byAdding: .day, value: 7, to: Date())!.startOfDay)
        context.insert(stay)
        // The return leg: JourneyPrefill sets its fromPlace to the last stay,
        // so it MATCHES the stay by name — and its 21:15 departure is airline
        // data, not something a hotel checkout may overwrite.
        let departure = Calendar.current.date(bySettingHour: 21, minute: 15, second: 0,
                                              of: Calendar.current.date(byAdding: .day, value: 7, to: Date())!)!
        let flight = TravelSegment(tripID: trip.id, mode: .flight, label: "SQ 947",
                                   fromPlace: "Karma Kandara, Uluwatu", toPlace: "",
                                   departAt: departure)
        context.insert(flight)
        try? context.save()

        let result = await executor.run(.init(
            id: "f1", name: "update_stay",
            input: ["hotel": "Karma Kandara",
                    "new_depart_date": day(8)]))

        XCTAssertEqual(flight.departAt, departure,
                       "a flight's booked departure must survive a stay's dates moving")
        XCTAssertTrue(result.text.contains("NOT changed"),
                      "and the receipt must say the flight was left alone: \(result.text)")
        XCTAssertTrue(result.text.contains("SQ 947"), "naming which leg to check")
    }

    func testInvertedDatesAreRejectedBeforeAnythingIsWritten() async {
        let context = container.mainContext
        let trip = Trip(title: "Coorg", startDate: Date().startOfDay,
                        endDate: Calendar.current.date(byAdding: .day, value: 5, to: Date())!.startOfDay)
        context.insert(trip)
        let arrive = Calendar.current.date(byAdding: .day, value: 2, to: Date())!.startOfDay
        let depart = Calendar.current.date(byAdding: .day, value: 4, to: Date())!.startOfDay
        let stay = TripStay(tripID: trip.id, place: "Evolve Back",
                            arriveDate: arrive, departDate: depart)
        context.insert(stay)
        try? context.save()

        let result = await executor.run(.init(
            id: "b1", name: "update_stay",
            input: ["hotel": "Evolve Back", "new_depart_date": day(1)]))

        XCTAssertTrue(result.text.contains("nothing changed"))
        XCTAssertEqual(stay.arriveDate, arrive, "the refusal must not have written anything")
        XCTAssertEqual(stay.departDate, depart)
    }

    func testMovingOneStayLeavesAnotherHotelsDrivesAlone() async {
        let context = container.mainContext
        let trip = Trip(title: "Mysore", startDate: Date().startOfDay,
                        endDate: Calendar.current.date(byAdding: .day, value: 9, to: Date())!.startOfDay)
        context.insert(trip)
        context.insert(TripStay(tripID: trip.id, place: "Radisson Mysore",
                                arriveDate: Calendar.current.date(byAdding: .day, value: 2, to: Date())!.startOfDay,
                                departDate: Calendar.current.date(byAdding: .day, value: 4, to: Date())!.startOfDay))
        // A different hotel in the same city — its drive must not be dragged
        // along just because both names contain "Mysore".
        let otherArrival = Calendar.current.date(byAdding: .day, value: 6, to: Date())!
        let otherDrive = TravelSegment(tripID: trip.id, mode: .drive, label: "Drive to Grand Mysore",
                                       fromPlace: "Home", toPlace: "Grand Mysore",
                                       arriveBy: otherArrival)
        context.insert(otherDrive)
        try? context.save()

        _ = await executor.run(.init(
            id: "b2", name: "update_stay",
            input: ["hotel": "Radisson Mysore", "new_arrive_date": day(3),
                    "new_depart_date": day(5)]))

        XCTAssertEqual(otherDrive.arriveBy, otherArrival,
                       "sharing a city name is not sharing a booking")
    }

    func testMovingAStayWithoutChangingDatesTouchesNoJourneys() async {
        let context = container.mainContext
        context.insert(TripStay(tripID: UUID(), place: "Radisson Mysore",
                                arriveDate: Date().startOfDay, departDate: Date().startOfDay))
        try? context.save()

        let result = await executor.run(.init(
            id: "v4", name: "update_stay",
            input: ["hotel": "Radisson", "new_address": "Mysuru"]))

        XCTAssertFalse(result.text.contains("Re-measured"),
                       "an address-only edit must not churn journeys: \(result.text)")
    }

    func testCheckInAndCheckOutTimesAreStoredAndDefaulted() async {
        let context = container.mainContext
        _ = await executor.run(.init(
            id: "w1", name: "add_stay",
            input: ["trip": "Ooty", "hotel": "Western Valley Resort",
                    "arrive_date": day(3), "depart_date": day(5),
                    "checkin_time": "15:00", "checkout_time": "10:00"]))
        _ = await executor.run(.init(
            id: "w2", name: "add_stay",
            input: ["trip": "Coorg", "hotel": "Evolve Back",
                    "arrive_date": day(20), "depart_date": day(22)]))

        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        let ooty = stays.first { $0.place.contains("Western Valley") }
        let coorg = stays.first { $0.place.contains("Evolve") }
        XCTAssertEqual(ooty?.checkinMinute, 15 * 60)
        XCTAssertEqual(ooty?.checkoutMinute, 10 * 60)
        XCTAssertEqual(coorg?.checkinMinute, StayWindow.defaultCheckin,
                       "unstated policy falls back to the common window")
        XCTAssertEqual(coorg?.checkoutMinute, StayWindow.defaultCheckout)
    }

    // MARK: flight-number dedup

    func testSameFlightWithADifferentDestinationStringUpdatesInsteadOfDuplicating() async {
        let context = container.mainContext
        context.insert(Trip(title: "Colombo",
                            startDate: Calendar.current.date(byAdding: .day, value: 20, to: Date())!.startOfDay,
                            endDate: Calendar.current.date(byAdding: .day, value: 23, to: Date())!.startOfDay))
        try? context.save()

        _ = await executor.run(.init(
            id: "d1", name: "add_journey",
            input: ["trip": "Colombo", "mode": "flight", "label": "UL 174",
                    "to": "Colombo", "date": day(20), "time": "09:45"]))
        // Same aircraft, described differently — used to slip past dedup.
        _ = await executor.run(.init(
            id: "d2", name: "add_journey",
            input: ["trip": "Colombo", "mode": "flight", "label": "UL174",
                    "to": "Bandaranaike Airport", "date": day(20), "time": "09:45"]))

        let segs = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
        XCTAssertEqual(segs.count, 1, "a flight number identifies the leg on its own")
    }

    func testDifferentFlightNumbersStayTwoLegs() async {
        let context = container.mainContext
        context.insert(Trip(title: "Colombo",
                            startDate: Calendar.current.date(byAdding: .day, value: 20, to: Date())!.startOfDay,
                            endDate: Calendar.current.date(byAdding: .day, value: 23, to: Date())!.startOfDay))
        try? context.save()

        _ = await executor.run(.init(
            id: "d3", name: "add_journey",
            input: ["trip": "Colombo", "mode": "flight", "label": "UL 174",
                    "to": "Colombo", "date": day(20), "time": "09:45"]))
        _ = await executor.run(.init(
            id: "d4", name: "add_journey",
            input: ["trip": "Colombo", "mode": "flight", "label": "UL 173",
                    "to": "Bengaluru", "date": day(23), "time": "20:30"]))

        let segs = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
        XCTAssertEqual(segs.count, 2, "outbound and return are two different flights")
    }

    // MARK: delete_stay two-phase

    func testDeleteStayPreviewsThenDeletesOnConfirm() async {
        let context = container.mainContext
        let trip = Trip(title: "Ooty", startDate: Date().startOfDay, endDate: Date().startOfDay)
        context.insert(trip)
        context.insert(TripStay(tripID: trip.id, place: "Western Valley Resort",
                                address: "", arriveDate: Date().startOfDay,
                                departDate: Date().startOfDay))
        try? context.save()

        let preview = await executor.run(.init(
            id: "t3", name: "delete_stay", input: ["hotel": "Western Valley"]))
        XCTAssertTrue(preview.text.contains("PREVIEW"), "first call must preview")
        XCTAssertEqual(((try? context.fetch(FetchDescriptor<TripStay>())) ?? []).count, 1,
                       "nothing deleted before confirmation")

        let done = await executor.run(.init(
            id: "t4", name: "delete_stay",
            input: ["hotel": "Western Valley", "confirmed": true]))
        XCTAssertTrue(done.text.contains("Deleted"))
        XCTAssertEqual(((try? context.fetch(FetchDescriptor<TripStay>())) ?? []).count, 0)
    }

    // MARK: add_journey date guard

    func testAddJourneyRefusesMissingDate() async {
        let context = container.mainContext
        context.insert(Trip(title: "Mysore", startDate: Date().startOfDay,
                            endDate: Calendar.current.date(byAdding: .day, value: 2, to: Date())!.startOfDay))
        try? context.save()

        let result = await executor.run(.init(
            id: "t5", name: "add_journey",
            input: ["trip": "Mysore", "mode": "drive", "to": "Home", "time": "18:00"]))

        XCTAssertTrue(result.text.contains("Which date"), "must ask, never assume today")
        XCTAssertEqual(((try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []).count, 0)
    }

    // MARK: measured auto-transition (the stub makes it deterministic)

    func testSecondStayGetsMeasuredDriveTransition() async throws {
        let context = container.mainContext
        _ = await executor.run(.init(
            id: "m1", name: "add_stay",
            input: ["trip": "Mysore", "hotel": "Radisson Mysore",
                    "arrive_date": day(10), "depart_date": day(12)]))
        _ = await executor.run(.init(
            id: "m2", name: "add_stay",
            input: ["trip": "Mysore", "hotel": "CGH Earth Wayanad",
                    "arrive_date": day(12), "depart_date": day(14)]))

        // The measure runs in a background Task — poll briefly.
        var seg: TravelSegment?
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let segs = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
            if let s = segs.first(where: { $0.travelMinutes > 0 }) { seg = s; break }
        }
        XCTAssertNotNil(seg, "auto transition must exist and get measured")
        XCTAssertEqual(seg?.travelMinutes, 42, "measured via the injected stub")
        XCTAssertEqual(seg?.mode, .drive)
        XCTAssertTrue(seg?.label.contains("Radisson") ?? false)
    }

    // MARK: flight zone caveat + replan hint

    func testFlightWithoutZonesGetsCorrectionNote() async {
        let context = container.mainContext
        context.insert(Trip(title: "Colombo",
                            startDate: Calendar.current.date(byAdding: .day, value: 20, to: Date())!.startOfDay,
                            endDate: Calendar.current.date(byAdding: .day, value: 23, to: Date())!.startOfDay))
        try? context.save()

        let result = await executor.run(.init(
            id: "z1", name: "add_journey",
            input: ["trip": "Colombo", "mode": "flight", "label": "UL 174",
                    "to": "Bengaluru Airport", "date": day(20), "time": "09:45"]))

        XCTAssertTrue(result.text.contains("no timezones stamped"),
                      "flight saved without zones must surface the gap: \(result.text)")
    }

    func testEditingTodaysEventSuggestsReplanOffer() async {
        let context = container.mainContext
        context.insert(DailyEvent(date: Date().startOfDay, title: "Standup",
                                  startMinute: 600, endMinute: 660))
        try? context.save()

        let result = await executor.run(.init(
            id: "r1", name: "edit_event",
            input: ["title": "Standup", "new_end": "12:00"]))

        XCTAssertTrue(result.text.contains("OFFER to replan"),
                      "time change on today must carry the replan hint: \(result.text)")
    }

    // MARK: relative time edits (no head-math)

    func testExtendByMinutesLengthensFromTheStoredEnd() async {
        let context = container.mainContext
        // Exactly the shape that broke: add_event's 3 h default, then "extend
        // it by an hour". The old absolute-only path SHRANK this to 22:00.
        _ = await executor.run(.init(
            id: "e0", name: "add_event",
            input: ["title": "Dinner with Arvind", "date": "today", "start_time": "20:00"]))
        var events = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        XCTAssertEqual(events.first?.endMinute, 23 * 60, "3 h default applies")

        let result = await executor.run(.init(
            id: "e1", name: "edit_event",
            input: ["title": "Dinner with Arvind", "extend_by_minutes": 60]))

        events = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        XCTAssertEqual(events.count, 1, "no duplicate")
        XCTAssertEqual(events.first?.startMinute, 20 * 60)
        XCTAssertEqual(events.first?.endMinute, 24 * 60, "23:00 + 60 = 24:00, never a shrink")
        XCTAssertTrue(result.text.contains("20:00–23:00 → 20:00–24:00"),
                      "receipt quotes old AND new: \(result.text)")
    }

    func testAddEventAnnouncesAnAssumedEndTime() async {
        let result = await executor.run(.init(
            id: "e2", name: "add_event",
            input: ["title": "Lunch", "date": "today", "start_time": "13:00"]))
        XCTAssertTrue(result.text.contains("assumed"),
                      "an invented end time must announce itself: \(result.text)")
    }

    func testShiftByMinutesMovesBothEndsAndKeepsDuration() async {
        let context = container.mainContext
        context.insert(DailyEvent(date: Date().startOfDay, title: "Movie with Karan",
                                  startMinute: 21 * 60, endMinute: 23 * 60))
        try? context.save()

        _ = await executor.run(.init(
            id: "e3", name: "edit_event",
            input: ["title": "Movie", "shift_by_minutes": 30]))

        let events = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        XCTAssertEqual(events.first?.startMinute, 21 * 60 + 30)
        XCTAssertEqual(events.first?.endMinute, 23 * 60 + 30, "duration preserved, not stretched")
    }

    func testLateNightDefaultEndStaysInsideTheDayAndStillExtends() async {
        let context = container.mainContext
        // The 23:00 case: an unclamped 3 h default stored 26:00, and extending
        // then clamped to 24:00 — a two-hour SHRINK on an extend request.
        _ = await executor.run(.init(
            id: "n1", name: "add_event",
            input: ["title": "Drinks with Sam", "date": "today", "start_time": "23:00"]))
        var events = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        XCTAssertEqual(events.first?.endMinute, 24 * 60, "assumed end clamped to midnight")

        let before = events.first?.endMinute ?? 0
        let result = await executor.run(.init(
            id: "n2", name: "edit_event",
            input: ["title": "Drinks with Sam", "extend_by_minutes": 60]))

        events = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        XCTAssertGreaterThanOrEqual(events.first?.endMinute ?? 0, before,
                                    "an extend must never shorten the event")
        XCTAssertTrue(result.text.contains("only 0 min could be applied"),
                      "a clamped extend must say what actually happened: \(result.text)")
    }

    func testRelativeEditOnTodayAlsoCarriesTheReplanHint() async {
        let context = container.mainContext
        context.insert(DailyEvent(date: Date().startOfDay, title: "Dinner with Priya",
                                  startMinute: 19 * 60, endMinute: 21 * 60))
        try? context.save()

        let result = await executor.run(.init(
            id: "r2", name: "edit_event",
            input: ["title": "Dinner with Priya", "extend_by_minutes": 60]))

        XCTAssertTrue(result.text.contains("OFFER to replan"),
                      "the PREFERRED relative path must prompt the replan too: \(result.text)")
    }

    func testExtendNeverEndsBeforeItStarts() async {
        let context = container.mainContext
        context.insert(DailyEvent(date: Date().startOfDay, title: "Standup",
                                  startMinute: 600, endMinute: 660))
        try? context.save()

        _ = await executor.run(.init(
            id: "e4", name: "edit_event",
            input: ["title": "Standup", "extend_by_minutes": -600]))

        let events = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        XCTAssertEqual(events.first?.endMinute, 600, "clamped to the start, never inverted")
    }

    // MARK: calendar tombstones

    func testDeletedSyncedEventIsTombstoned() async {
        let context = container.mainContext
        context.insert(DailyEvent(date: Date().startOfDay.addingTimeInterval(86400),
                                  title: "Bhadra Tiger Reserve Tour",
                                  startMinute: 0, endMinute: 0, isAllDay: true,
                                  externalID: "gcal-bhadra-1"))
        try? context.save()

        _ = await executor.run(.init(
            id: "t6", name: "delete_event", input: ["title": "Bhadra Tiger Reserve"]))

        XCTAssertEqual(((try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []).count, 0)
        XCTAssertEqual(CalendarTombstone.ids(in: context), ["gcal-bhadra-1"],
                       "the calendar ID must be tombstoned so sync can't resurrect it")
    }
}
