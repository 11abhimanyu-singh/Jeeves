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
