//
//  AnchorExtractionServiceTests.swift
//  JeevesTests
//
//  Exercises AnchorExtractionService.parse against real Anthropic
//  Messages-API response shapes carrying anchor JSON — bare JSON, ```json
//  fenced JSON, JSON wrapped in prose, a valid-but-empty result, plus the
//  edge cases that historically break extraction (empty content, a
//  tool_use-only turn, a text-less block, and non-JSON text) — with no API
//  key and no network.
//

import XCTest
@testable import Jeeves

final class AnchorExtractionServiceTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    /// Wrap an assistant `text` string in a realistic /v1/messages envelope.
    /// Uses JSONSerialization so the anchor JSON (which itself contains quotes
    /// and braces) is escaped correctly into the `text` field.
    private func response(text: String) -> Data {
        let payload: [String: Any] = [
            "id": "msg_01ZfY7z8w9",
            "type": "message",
            "role": "assistant",
            "model": "claude-sonnet-5",
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// Build the envelope from an arbitrary `content` JSON fragment (for the
    /// non-text edge cases).
    private func rawResponse(content: String) -> Data {
        data("""
        {"type": "message", "role": "assistant", "content": \(content), "stop_reason": "end_turn"}
        """)
    }

    // MARK: - Happy paths

    func testParsesBareAnchorJSON() {
        let json = response(text: """
        {"events": [{"title": "MLR show", "startTime": "19:00", "endTime": "22:00", "venue": "MLR Convention Centre", "leavingFrom": "Home"}], "gymToday": true, "gymTime": "06:30"}
        """)
        let anchors = AnchorExtractionService.parse(json)
        XCTAssertNotNil(anchors)
        XCTAssertEqual(anchors?.events.count, 1)
        XCTAssertEqual(anchors?.events.first?.title, "MLR show")
        XCTAssertEqual(anchors?.events.first?.startTime, "19:00")
        XCTAssertEqual(anchors?.events.first?.endTime, "22:00")
        XCTAssertEqual(anchors?.events.first?.venue, "MLR Convention Centre")
        XCTAssertEqual(anchors?.events.first?.leavingFrom, "Home")
        XCTAssertEqual(anchors?.gymToday, true)
        XCTAssertEqual(anchors?.gymTime, "06:30")
    }

    func testParsesFencedJSON() {
        // The model routinely wraps JSON in a ```json code fence despite being
        // told not to — parse must strip it.
        let json = response(text: """
        ```json
        {"events": [{"title": "Dentist", "startTime": "14:00", "endTime": "15:00", "venue": "MG Road", "leavingFrom": "Work"}], "gymToday": false, "gymTime": null}
        ```
        """)
        let anchors = AnchorExtractionService.parse(json)
        XCTAssertEqual(anchors?.events.first?.title, "Dentist")
        XCTAssertEqual(anchors?.events.first?.leavingFrom, "Work")
        XCTAssertEqual(anchors?.gymToday, false)
        XCTAssertNil(anchors?.gymTime)
    }

    func testParsesJSONWrappedInProse() {
        // Extraneous prose around the object must be sliced off by the
        // first-"{" / last-"}" carve.
        let json = response(text: """
        Sure — here are the anchors I found:
        {"events": [{"title": "Team sync", "startTime": "10:00", "endTime": "10:30", "venue": null, "leavingFrom": "Home"}], "gymToday": null, "gymTime": null}
        Let me know if that looks right!
        """)
        let anchors = AnchorExtractionService.parse(json)
        XCTAssertEqual(anchors?.events.first?.title, "Team sync")
        XCTAssertNil(anchors?.events.first?.venue)
        XCTAssertNil(anchors?.gymToday)
    }

    func testMissingOptionalEventFieldsDefaultToNil() {
        // Only title + startTime present; endTime/venue/leavingFrom absent.
        let json = response(text: """
        {"events": [{"title": "Standup", "startTime": "09:15"}], "gymToday": null, "gymTime": null}
        """)
        let anchors = AnchorExtractionService.parse(json)
        let event = anchors?.events.first
        XCTAssertEqual(event?.title, "Standup")
        XCTAssertEqual(event?.startTime, "09:15")
        XCTAssertNil(event?.endTime)
        XCTAssertNil(event?.venue)
        XCTAssertNil(event?.leavingFrom)
    }

    func testValidButEmptyResultIsNotNil() {
        // "Nothing planning-relevant" is a successful parse with empty events —
        // it must NOT collapse to nil (that would be read as a failure).
        let json = response(text: """
        {"events": [], "gymToday": null, "gymTime": null}
        """)
        let anchors = AnchorExtractionService.parse(json)
        XCTAssertNotNil(anchors)
        XCTAssertEqual(anchors?.events.count, 0)
        XCTAssertNil(anchors?.gymToday)
        XCTAssertNil(anchors?.gymTime)
    }

    func testGymOnlyMessage() {
        let json = response(text: """
        {"events": [], "gymToday": true, "gymTime": "18:00"}
        """)
        let anchors = AnchorExtractionService.parse(json)
        XCTAssertTrue(anchors?.events.isEmpty ?? false)
        XCTAssertEqual(anchors?.gymToday, true)
        XCTAssertEqual(anchors?.gymTime, "18:00")
    }

    // MARK: - Edge cases that break extraction

    func testMalformedAnchorJSONYieldsNil() {
        // Text carries braces but isn't valid JSON → decode fails → nil.
        let json = response(text: "Here you go: { this is not : valid json }")
        XCTAssertNil(AnchorExtractionService.parse(json))
    }

    func testTextWithNoJSONObjectYieldsNil() {
        // No braces at all to carve out → nil.
        let json = response(text: "I couldn't find any events or gym plans for today.")
        XCTAssertNil(AnchorExtractionService.parse(json))
    }

    func testToolUseOnlyResponseYieldsNil() {
        let json = rawResponse(content: """
        [ {"type": "tool_use", "id": "toolu_01C", "name": "extract", "input": {"foo": "bar"}} ]
        """)
        XCTAssertNil(AnchorExtractionService.parse(json))
    }

    func testEmptyContentYieldsNil() {
        XCTAssertNil(AnchorExtractionService.parse(rawResponse(content: "[]")))
    }

    func testTextBlockWithMissingTextFieldYieldsNil() {
        let json = rawResponse(content: """
        [ {"type": "text"} ]
        """)
        XCTAssertNil(AnchorExtractionService.parse(json))
    }

    func testApiErrorBodyYieldsNil() {
        let json = data("""
        {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}
        """)
        XCTAssertNil(AnchorExtractionService.parse(json))
    }

    func testJunkYieldsNil() {
        XCTAssertNil(AnchorExtractionService.parse(data("not json")))
    }
}
