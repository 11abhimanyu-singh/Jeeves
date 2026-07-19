//
//  ModelTests.swift
//  JeevesTests
//
//  Covers the plain data models and value types: SwiftData enum round-trips
//  (stored as raw strings), sensible defaults, ChatTurn's plan persistence,
//  and EventDraft's construction from a detected ticket.
//

import XCTest
@testable import Jeeves

final class ModelTests: XCTestCase {

    // MARK: SavedLocation

    func testLocationDefaultFacilities() {
        XCTAssertTrue(LocationKind.gym.defaultFacilities.contains("shower"))
        XCTAssertTrue(LocationKind.gym.defaultFacilities.contains("weightlifting"))
        XCTAssertTrue(LocationKind.home.defaultFacilities.contains("lunch"))
        XCTAssertTrue(LocationKind.work.defaultFacilities.isEmpty)
    }

    func testLocationKindRoundTripsThroughRawStorage() {
        let loc = SavedLocation(kind: .gym, address: "Gym Rd")
        XCTAssertEqual(loc.kindRaw, "Gym")
        loc.kind = .work
        XCTAssertEqual(loc.kindRaw, "Work")
        XCTAssertEqual(loc.kind, .work)
    }

    func testLocationSeedsDefaultFacilitiesWhenNoneGiven() {
        XCTAssertEqual(SavedLocation(kind: .gym).facilities, LocationKind.gym.defaultFacilities)
        XCTAssertEqual(SavedLocation(kind: .home, address: "", facilities: ["only this"]).facilities, ["only this"])
    }

    // MARK: DailyEvent

    func testEventEnumsRoundTrip() {
        let e = DailyEvent(date: Date(), title: "Movie", startMinute: 840, endMinute: 1020,
                           destinationAddress: "Cinema", outboundStart: .gym, source: .calendar)
        XCTAssertEqual(e.outboundStartRaw, "Gym")
        XCTAssertEqual(e.sourceRaw, "Calendar")
        e.outboundStart = .home
        XCTAssertEqual(e.outboundStart, .home)
        XCTAssertEqual(e.source, .calendar)
    }

    // MARK: Book

    func testBookDefaults() {
        let b = Book(title: "Zero to One", author: "Peter Thiel")
        XCTAssertEqual(b.status, .unread)
        XCTAssertEqual(b.libraryStatus, .owned)
        XCTAssertEqual(b.currentPage, 0)
        XCTAssertNil(b.rating)
        XCTAssertNil(b.dateFinished)
    }

    func testReadingStatusReadRawValue() {
        // The "finished" case is user-labelled "Read" — guard the label doesn't drift.
        XCTAssertEqual(ReadingStatus.finished.rawValue, "Read")
    }

    // MARK: ChatTurn

    func testChatTurnPersistsAndDecodesPlan() {
        let plan = GeneratedPlan(
            blocks: [GeneratedBlock(title: "Lunch", startTime: "13:00", endTime: "13:45", note: nil, isAnchor: false, kind: "lunch")],
            dropped: [], shrunk: [], summary: "ok", boundaryTime: nil
        )
        let json = ChatTurn.encodePlan(plan)
        XCTAssertNotNil(json)

        let turn = ChatTurn(role: "assistant", content: "", day: Date().startOfDay, planJSON: json)
        XCTAssertFalse(turn.isUser)
        let decoded = turn.plan
        XCTAssertEqual(decoded?.blocks.first?.title, "Lunch")
        XCTAssertEqual(decoded?.summary, "ok")
    }

    func testChatTurnWithoutPlanJSONHasNoPlan() {
        let turn = ChatTurn(role: "user", content: "hi", day: Date().startOfDay)
        XCTAssertTrue(turn.isUser)
        XCTAssertNil(turn.plan)
    }

    // MARK: DailyPlanState — the committed day plan persists

    func testDailyPlanStatePersistsPlan() {
        let plan = GeneratedPlan(
            blocks: [GeneratedBlock(title: "Reading", startTime: "08:00", endTime: "09:30", note: nil, isAnchor: true, kind: "activity")],
            dropped: [], shrunk: [], summary: "A calm day.", boundaryTime: nil
        )
        let state = DailyPlanState(date: Date().startOfDay, hasGymToday: false, gymMinute: nil)
        XCTAssertNil(state.plan)
        state.storePlan(plan, isOffline: true)
        XCTAssertEqual(state.plan?.blocks.first?.title, "Reading")
        XCTAssertEqual(state.plan?.summary, "A calm day.")
        XCTAssertTrue(state.generatedPlanIsOffline)
    }

    // MARK: EventDraft (from a detected ticket)

    func testEventDraftFromDetectedParsesTimesAndVenue() {
        let detected = DetectedEvent(title: "Baithak Live", date: "2026-07-19", startTime: "19:00", endTime: "21:00", venue: "MLR Convention Centre")
        let draft = EventDraft(detected: detected)
        XCTAssertEqual(draft.title, "Baithak Live")
        XCTAssertEqual(draft.startMinute, 19 * 60)
        XCTAssertEqual(draft.endMinute, 21 * 60)
        XCTAssertEqual(draft.address, "MLR Convention Centre")
        XCTAssertEqual(draft.source, .screenshot)
    }

    func testEventDraftDefaultsEndSpanWhenMissing() {
        let detected = DetectedEvent(title: "Show", date: nil, startTime: "18:00", endTime: nil, venue: nil)
        let draft = EventDraft(detected: detected)
        XCTAssertEqual(draft.startMinute, 18 * 60)
        XCTAssertEqual(draft.endMinute, 18 * 60 + 180, "no end time → default ~3h span")
        XCTAssertEqual(draft.address, "")
    }
}
