//
//  ChatReceiptTests.swift
//  JeevesTests
//
//  Every string in here is a VERBATIM receipt from ChatToolExecutor. That is
//  the contract: the parser reads what the tools actually emit, so if a
//  receipt's wording changes, one of these fails and the card stops silently
//  degrading to prose.
//

import XCTest
@testable import Jeeves

final class ChatReceiptTests: XCTestCase {

    // MARK: the shapes the executor emits

    func testEventTimeChangeCarriesBothEnds() throws {
        let r = try XCTUnwrap(ChatReceipt.parse(
            tool: "edit_event",
            result: "Updated 1 event(s) (Mon 3 Aug): 20:00–23:00 → 20:00–24:00."))
        XCTAssertEqual(r.was, "20:00–23:00")
        XCTAssertEqual(r.now, "20:00–24:00")
        XCTAssertEqual(r.label, "Mon 3 Aug", "the tool's own bookkeeping is not a label")
        XCTAssertEqual(r.kind, .updated)
    }

    /// A pure day move changes no times, so its only before/after pair lives
    /// in the trailing sentence. This is t1-11, which scored 2–3/10 before the
    /// receipt quoted the days at all.
    func testDayShiftIsReadFromTheTrailingMovedClause() throws {
        let r = try XCTUnwrap(ChatReceipt.parse(
            tool: "edit_event",
            result: "Updated 1 event(s) (Tue 4 Aug): . Moved Mon 3 Aug → Tue 4 Aug."))
        XCTAssertEqual(r.was, "Mon 3 Aug")
        XCTAssertEqual(r.now, "Tue 4 Aug")
    }

    func testStayRangeChange() throws {
        let r = try XCTUnwrap(ChatReceipt.parse(
            tool: "update_stay",
            result: "CGH Earth Wayanad: 13 Sep – 15 Sep → 13 Sep – 19 Sep."))
        XCTAssertEqual(r.label, "CGH Earth Wayanad")
        XCTAssertEqual(r.was, "13 Sep – 15 Sep")
        XCTAssertEqual(r.now, "13 Sep – 19 Sep")
    }

    func testTripUsesTheParentheticalWasForm() throws {
        let r = try XCTUnwrap(ChatReceipt.parse(
            tool: "update_trip",
            result: "'Mysore' is now 11 Sep–14 Sep (was 11 Sep–13 Sep). Days no longer covered go back to the planner."))
        XCTAssertEqual(r.label, "Mysore")
        XCTAssertEqual(r.was, "11 Sep–13 Sep")
        XCTAssertEqual(r.now, "11 Sep–14 Sep")
    }

    func testDeletionHasAValueButNoSuccessor() throws {
        let r = try XCTUnwrap(ChatReceipt.parse(
            tool: "delete_stay",
            result: "Deleted the Western Valley Resort stay (10 Aug – 12 Aug). Also removed 1 journey(s) that led there: CGH Earth Wayanad → Western Valley Resort."))
        XCTAssertEqual(r.kind, .deleted)
        XCTAssertNil(r.was)
        XCTAssertEqual(r.now, "10 Aug – 12 Aug")
        XCTAssertTrue(r.label.contains("Western Valley"))
        XCTAssertNotNil(r.caveat, "the journeys that went with it are the caveat")
    }

    func testCreationIsOnlyClaimedByToolsThatCreate() throws {
        let made = try XCTUnwrap(ChatReceipt.parse(
            tool: "add_stay",
            result: "Stay added to 'Mysore': CGH Earth Wayanad, 7 Aug – 10 Aug."))
        XCTAssertEqual(made.kind, .created)
        XCTAssertNil(made.was)
        XCTAssertEqual(made.now, "CGH Earth Wayanad, 7 Aug – 10 Aug")

        // The same shape from a READ tool must not become an "added" card.
        XCTAssertNil(ChatReceipt.parse(
            tool: "fetch_app_data",
            result: "Wayanad: CGH Earth Wayanad, 7 Aug – 10 Aug."))
    }

    // MARK: what must NOT become a card

    func testPreviewsRefusalsAndQuestionsProduceNoCard() {
        let none = [
            ("delete_stay", "PREVIEW ONLY — nothing deleted yet. This removes the Western Valley Resort stay (10 Aug – 12 Aug) from 'Hills'."),
            ("update_trip", "Those dates run through 'Colombo' (20 Sep–23 Sep) — two trips cannot own the same days, so NOTHING was changed."),
            ("update_stay", "That checkout (Sat 9 Aug) is before check-in (Mon 11 Aug) — nothing changed."),
            ("add_stay", "Which dates? Give arrive_date and depart_date as YYYY-MM-DD — I won't guess."),
            ("delete_trip", "No trip covers Fri 15 Aug — there is nothing to delete on that day."),
        ]
        for (tool, result) in none {
            XCTAssertNil(ChatReceipt.parse(tool: tool, result: result),
                         "a card is a claim the store moved: \(result.prefix(48))")
        }
    }

    // MARK: caveats — the half the model likes to bury

    func testClampIsCapturedAsACaveatAndNotAsTheNewValue() throws {
        let r = try XCTUnwrap(ChatReceipt.parse(
            tool: "edit_event",
            result: "Updated 1 event(s) (Mon 3 Aug): 20:00–24:00 → 20:30–24:00; SHORTER BY 30 MIN — it would have run past midnight. NOTE: the event now ends at 24:00, NOT 30 min later as asked."))
        XCTAssertEqual(r.now, "20:30–24:00", "the warning must not leak into the new value")
        let caveat = try XCTUnwrap(r.caveat)
        XCTAssertTrue(caveat.contains("SHORTER BY 30 MIN"), caveat)
    }

    func testHotelPolicyConflictSurvivesAsACaveat() throws {
        let r = try XCTUnwrap(ChatReceipt.parse(
            tool: "update_stay",
            result: "Western Valley Resort: 10 Aug – 12 Aug → 11 Aug – 13 Aug. HOTEL POLICY — repeat this to the user verbatim, do not resolve it silently: Drive: leaving at checkout (11:30) gets you there 12:12, which is 1h 48m before check-in opens at 14:00."))
        let caveat = try XCTUnwrap(r.caveat)
        XCTAssertTrue(caveat.contains("before check-in opens"), caveat)
        XCTAssertFalse(caveat.contains("repeat this to the user"),
                       "instructions aimed at the model are not shown to the user")
    }

    // MARK: collection

    func testOneChangeRestatedTwiceIsOneCard() {
        let calls = [
            (tool: "update_stay", result: "CGH Earth Wayanad: 13 Sep – 15 Sep → 13 Sep – 19 Sep."),
            (tool: "update_stay", result: "CGH Earth Wayanad: 13 Sep – 15 Sep → 13 Sep – 19 Sep."),
            (tool: "update_trip", result: "'Mysore' is now 11 Sep–19 Sep (was 11 Sep–15 Sep)."),
        ]
        XCTAssertEqual(ChatReceipt.parseAll(calls).count, 2)
    }

    func testRoundTripsThroughStorage() throws {
        let original = try XCTUnwrap(ChatReceipt.parse(
            tool: "update_stay",
            result: "CGH Earth Wayanad: 13 Sep – 15 Sep → 13 Sep – 19 Sep."))
        let decoded = ChatReceipt.decode(ChatReceipt.encode([original]))
        XCTAssertEqual(decoded.first?.was, original.was)
        XCTAssertEqual(decoded.first?.now, original.now)
        XCTAssertTrue(ChatReceipt.decode(nil).isEmpty)
        XCTAssertNil(ChatReceipt.encode([]), "no receipts stores nothing, not '[]'")
    }

    // MARK: the activity label

    func testActivityNamesTheCollectionBeingRead() {
        XCTAssertEqual(ToolActivity.label(for: "fetch_app_data", input: ["collection": "journeys"]),
                       "Reading your journeys…")
        XCTAssertEqual(ToolActivity.label(for: "fetch_app_data", input: ["collection": "trips"]),
                       "Reading your trips…")
        XCTAssertEqual(ToolActivity.label(for: "update_stay"), "Updating the hotel…")
        // An unknown tool still says something rather than going silent.
        XCTAssertFalse(ToolActivity.label(for: "something_new").isEmpty)
    }
}
