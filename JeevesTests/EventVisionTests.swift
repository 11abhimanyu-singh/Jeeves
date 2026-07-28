//
//  EventVisionTests.swift
//  JeevesTests
//
//  Exercises EventVisionService.parse against real Anthropic Messages-API
//  response shapes — plain JSON text, ```json-fenced text, null / missing
//  optional fields, an API error body, no text block, and malformed event
//  JSON — with no API key and no network. This is the self-test for the
//  ticket-screenshot parse path.
//

import XCTest
@testable import Jeeves

final class EventVisionTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    /// Wraps an assistant text string in the exact envelope the Anthropic
    /// Messages API returns. JSONSerialization escapes the inner JSON the
    /// same way the real API does when the `text` field holds a JSON string.
    private func anthropicResponse(text: String) -> Data {
        let obj: [String: Any] = [
            "id": "msg_01XYZ",
            "type": "message",
            "role": "assistant",
            "model": "claude-sonnet-5",
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 900, "output_tokens": 60],
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - Happy path

    func testParsesFullEvent() {
        let response = anthropicResponse(text: """
        {"title": "Interstellar", "date": "2026-07-28", "startTime": "19:30", "endTime": "22:30", "venue": "PVR Phoenix Mall, Lower Parel"}
        """)
        let event = EventVisionService.parse(response)

        XCTAssertNotNil(event)
        XCTAssertEqual(event?.title, "Interstellar")
        XCTAssertEqual(event?.date, "2026-07-28")
        XCTAssertEqual(event?.startTime, "19:30")
        XCTAssertEqual(event?.endTime, "22:30")
        XCTAssertEqual(event?.venue, "PVR Phoenix Mall, Lower Parel")
    }

    /// Claude often wraps JSON in a ```json fence; parse must strip it.
    func testParsesFencedJSON() {
        let response = anthropicResponse(text: """
        ```json
        {"title": "Coldplay: Music of the Spheres", "date": "2026-07-28", "startTime": "18:00", "endTime": "21:00", "venue": "DY Patil Stadium"}
        ```
        """)
        let event = EventVisionService.parse(response)
        XCTAssertEqual(event?.title, "Coldplay: Music of the Spheres")
        XCTAssertEqual(event?.venue, "DY Patil Stadium")
        XCTAssertEqual(event?.startTime, "18:00")
    }

    // MARK: - Missing / null optionals ("nothing detected" for a field)

    /// The end time and venue address weren't on the ticket → nulls. Only the
    /// title is guaranteed; every other field is optional and may be null.
    func testNullOptionalFields() {
        let response = anthropicResponse(text: """
        {"title": "Dinner Reservation", "date": "2026-07-28", "startTime": "20:00", "endTime": null, "venue": null}
        """)
        let event = EventVisionService.parse(response)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.title, "Dinner Reservation")
        XCTAssertEqual(event?.startTime, "20:00")
        XCTAssertNil(event?.endTime)
        XCTAssertNil(event?.venue)
    }

    /// Optional fields omitted entirely (not even present) must also decode.
    func testOmittedOptionalFields() {
        let response = anthropicResponse(text: """
        {"title": "Open Mic Night"}
        """)
        let event = EventVisionService.parse(response)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.title, "Open Mic Night")
        XCTAssertNil(event?.date)
        XCTAssertNil(event?.startTime)
        XCTAssertNil(event?.endTime)
        XCTAssertNil(event?.venue)
    }

    // MARK: - Failure modes (all yield nil, never throw)

    /// Anthropic error envelope (no `content`) → decode fails → nil.
    func testAPIErrorBodyYieldsNil() {
        let errorBody = data("""
        {"type": "error", "error": {"type": "rate_limit_error", "message": "rate limited"}}
        """)
        XCTAssertNil(EventVisionService.parse(errorBody))
    }

    /// A response with no text block → nothing to decode → nil.
    func testNoTextBlockYieldsNil() {
        let response = data("""
        {"content": [{"type": "tool_use", "text": null}]}
        """)
        XCTAssertNil(EventVisionService.parse(response))
    }

    /// Empty content array → no text block → nil.
    func testEmptyContentYieldsNil() {
        XCTAssertNil(EventVisionService.parse(data("{\"content\": []}")))
    }

    /// A text block that isn't a valid event object (missing the required
    /// `title`, or truncated) → nil.
    func testMalformedEventJSONYieldsNil() {
        // Truncated JSON.
        XCTAssertNil(EventVisionService.parse(anthropicResponse(text: "{\"title\": \"Movie\", \"date\":")))
        // Missing the required non-optional `title` field.
        XCTAssertNil(EventVisionService.parse(anthropicResponse(text: "{\"date\": \"2026-07-28\"}")))
    }

    /// Prose instead of JSON → nil.
    func testProseInsteadOfJSONYieldsNil() {
        let response = anthropicResponse(text: "This screenshot doesn't look like a ticket to me.")
        XCTAssertNil(EventVisionService.parse(response))
    }

    /// Non-JSON bytes and empty data → nil (no crash).
    func testGarbageYieldsNil() {
        XCTAssertNil(EventVisionService.parse(data("nonsense")))
        XCTAssertNil(EventVisionService.parse(Data()))
    }
}
