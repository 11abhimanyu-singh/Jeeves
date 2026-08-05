//
//  PlanGenerationTests.swift
//  JeevesTests
//
//  Exercises the pure response-parsing steps of PlanGenerationService against
//  real Anthropic Messages API payload shapes — text plan JSON, ```json-fenced
//  JSON, prose-wrapped JSON, a thinking block before the text (adaptive
//  thinking), a tool_use-only reply, an empty content array, an API error body,
//  and malformed plan JSON — with no network and no API key.
//
//  This is the self-test for plan parsing: the calendar bug that shipped was a
//  decode/mapping bug that a test over realistic payloads would have caught, so
//  the two testable steps (pull the text out of the MessageResponse, then decode
//  the GeneratedPlan from that text) are covered directly here.
//

import XCTest
@testable import Jeeves

final class PlanGenerationTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    /// Wraps content blocks in the exact top-level shape the Messages API
    /// returns. Building the body with JSONSerialization keeps the nested
    /// plan-JSON-inside-a-text-block escaping correct instead of hand-escaped.
    private func anthropicBody(content: [[String: Any]],
                               stopReason: String = "end_turn") -> Data {
        let body: [String: Any] = [
            "id": "msg_01ABC123",
            "type": "message",
            "role": "assistant",
            "model": "claude-opus-4-8",
            "content": content,
            "stop_reason": stopReason,
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 1200, "output_tokens": 480],
        ]
        return try! JSONSerialization.data(withJSONObject: body, options: [])
    }

    private func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    /// A valid plan. The "Lunch" block deliberately omits the optional `note`
    /// field to exercise GeneratedBlock.note being nil.
    private let planJSON = """
    {
      "blocks": [
        {"title": "Interview prep — Reading", "startTime": "08:00", "endTime": "09:30", "note": "preferred early slot", "isAnchor": false, "kind": "activity"},
        {"title": "Lunch", "startTime": "12:30", "endTime": "13:00", "isAnchor": false, "kind": "lunch"},
        {"title": "Sleep", "startTime": "23:00", "endTime": "07:00", "isAnchor": true, "kind": "sleep"}
      ],
      "dropped": ["Photography"],
      "shrunk": ["Interview prep — practice 120→70"],
      "summary": "A calm day with reading up front and an early lunch.",
      "boundaryTime": "20:30"
    }
    """

    // MARK: - Well-formed response, text is plain plan JSON

    func testParsesWellFormedPlanResponse() throws {
        let response = anthropicBody(content: [textBlock(planJSON)])

        let plan = try XCTUnwrap(PlanGenerationService.parse(response),
                                 "a valid plan JSON in the text block must parse")

        XCTAssertEqual(plan.blocks.count, 3)

        // Block 0 — full block with a note and computed minute-of-day.
        XCTAssertEqual(plan.blocks[0].title, "Interview prep — Reading")
        XCTAssertEqual(plan.blocks[0].startTime, "08:00")
        XCTAssertEqual(plan.blocks[0].endTime, "09:30")
        XCTAssertEqual(plan.blocks[0].note, "preferred early slot")
        XCTAssertFalse(plan.blocks[0].isAnchor)
        XCTAssertEqual(plan.blocks[0].kind, "activity")
        XCTAssertEqual(plan.blocks[0].startMinute, 8 * 60)   // 08:00
        XCTAssertEqual(plan.blocks[0].endMinute, 9 * 60 + 30) // 09:30

        // Block 1 — optional `note` absent must decode as nil (not throw).
        XCTAssertEqual(plan.blocks[1].title, "Lunch")
        XCTAssertNil(plan.blocks[1].note, "a block with no `note` key must decode with note == nil")
        XCTAssertEqual(plan.blocks[1].kind, "lunch")

        // Block 2 — the anchored Sleep block; endTime wraps past midnight.
        XCTAssertEqual(plan.blocks[2].title, "Sleep")
        XCTAssertTrue(plan.blocks[2].isAnchor)
        XCTAssertEqual(plan.blocks[2].kind, "sleep")
        XCTAssertEqual(plan.blocks[2].endMinute, 7 * 60) // 07:00 next day

        XCTAssertEqual(plan.dropped, ["Photography"])
        XCTAssertEqual(plan.shrunk, ["Interview prep — practice 120→70"])
        XCTAssertEqual(plan.summary, "A calm day with reading up front and an early lunch.")
        XCTAssertEqual(plan.boundaryTime, "20:30")
    }

    // MARK: - Text fenced in ```json (un-fencing preserved)

    func testParsesPlanFencedInCodeBlock() throws {
        let fenced = "```json\n\(planJSON)\n```"
        let response = anthropicBody(content: [textBlock(fenced)])

        let plan = try XCTUnwrap(PlanGenerationService.parse(response),
                                 "a ```json-fenced plan must be un-fenced and decoded")
        XCTAssertEqual(plan.blocks.count, 3)
        XCTAssertEqual(plan.summary, "A calm day with reading up front and an early lunch.")
    }

    // MARK: - Text wrapped in prose around the JSON object

    func testParsesPlanWrappedInProse() throws {
        let prose = "Here's the plan for your day:\n\n\(planJSON)\n\nLet me know if you'd like changes!"
        let response = anthropicBody(content: [textBlock(prose)])

        let plan = try XCTUnwrap(PlanGenerationService.parse(response),
                                 "the outermost {...} object must be extracted from surrounding prose")
        XCTAssertEqual(plan.boundaryTime, "20:30")
        XCTAssertEqual(plan.dropped, ["Photography"])
    }

    // MARK: - Thinking block precedes the text block (adaptive thinking)

    func testSkipsThinkingBlockToFindText() throws {
        // Opus 4.8 with adaptive thinking returns a thinking block (no `text`
        // field) before the answer text block.
        let response = anthropicBody(content: [
            ["type": "thinking", "thinking": "The gym is late, so shower goes in the morning...", "signature": "sig_abc"],
            textBlock(planJSON),
        ])

        let text = try XCTUnwrap(PlanGenerationService.extractText(from: response),
                                 "extractText must skip the thinking block and return the text block")
        XCTAssertTrue(text.contains("\"blocks\""))

        let plan = try XCTUnwrap(PlanGenerationService.parse(response))
        XCTAssertEqual(plan.blocks.count, 3)
    }

    // MARK: - Optional boundaryTime absent

    func testParsesPlanWithoutBoundaryTime() throws {
        let noBoundary = """
        {"blocks": [{"title": "Free time", "startTime": "20:30", "endTime": "23:00", "isAnchor": false, "kind": "free"}],
         "dropped": [], "shrunk": [], "summary": "Quiet evening."}
        """
        let plan = try XCTUnwrap(PlanGenerationService.parse(anthropicBody(content: [textBlock(noBoundary)])))
        XCTAssertNil(plan.boundaryTime, "boundaryTime is optional and may be absent")
        XCTAssertTrue(plan.dropped.isEmpty)
        XCTAssertTrue(plan.shrunk.isEmpty)
    }

    // MARK: - No usable text block → extractText / parse return nil

    func testToolUseOnlyReplyHasNoText() {
        // A reply that is only a tool_use block — no text block to read.
        let response = anthropicBody(content: [
            ["type": "tool_use", "id": "toolu_01", "name": "some_tool", "input": ["x": 1]],
        ], stopReason: "tool_use")

        XCTAssertNil(PlanGenerationService.extractText(from: response),
                     "a tool_use-only reply has no text block")
        XCTAssertNil(PlanGenerationService.parse(response))
    }

    func testEmptyContentArrayHasNoText() {
        let response = anthropicBody(content: [], stopReason: "end_turn")
        XCTAssertNil(PlanGenerationService.extractText(from: response),
                     "an empty content array yields no text")
        XCTAssertNil(PlanGenerationService.parse(response))
    }

    func testTextBlockWithEmptyStringIsTreatedAsNoText() {
        // A present-but-empty text block must be treated as "no text" (mirrors
        // the original `!text.isEmpty` guard) so the caller falls back.
        let response = anthropicBody(content: [textBlock("")])
        XCTAssertNil(PlanGenerationService.extractText(from: response))
        XCTAssertNil(PlanGenerationService.parse(response))
    }

    // MARK: - API error body (no content array)

    func testApiErrorBodyReturnsNil() {
        // The real network path rejects non-2xx before parse; extractText must
        // still fail cleanly (no `content` key) rather than crash.
        let errorBody = data("""
        {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded, please retry."}}
        """)
        XCTAssertNil(PlanGenerationService.extractText(from: errorBody))
        XCTAssertNil(PlanGenerationService.parse(errorBody))
    }

    func testGarbageBodyReturnsNil() {
        XCTAssertNil(PlanGenerationService.extractText(from: data("not json at all")))
        XCTAssertNil(PlanGenerationService.parse(data("not json at all")))
    }

    // MARK: - Text present but plan JSON malformed → decodePlan returns nil

    func testMalformedPlanJSONInTextReturnsNil() {
        let bad = "{ \"blocks\": [ {\"title\": \"Lunch\", }  broken"
        let response = anthropicBody(content: [textBlock(bad)])

        // The text IS present — extractText succeeds...
        XCTAssertEqual(PlanGenerationService.extractText(from: response), bad)
        // ...but the plan can't be decoded, so decodePlan / parse return nil
        // (the caller maps this to .unparsableResponse, distinct from empty).
        XCTAssertNil(PlanGenerationService.decodePlan(from: bad))
        XCTAssertNil(PlanGenerationService.parse(response))
    }

    func testTextWithNoJSONObjectReturnsNil() {
        let response = anthropicBody(content: [textBlock("I couldn't build a plan today, sorry.")])
        XCTAssertNotNil(PlanGenerationService.extractText(from: response))
        XCTAssertNil(PlanGenerationService.parse(response), "prose with no {...} object is not a plan")
    }

    // MARK: - decodePlan driven directly (no envelope)

    func testDecodePlanUnfencesRawText() throws {
        let plan = try XCTUnwrap(PlanGenerationService.decodePlan(from: "```json\n\(planJSON)\n```"))
        XCTAssertEqual(plan.blocks.first?.title, "Interview prep — Reading")

        let plan2 = try XCTUnwrap(PlanGenerationService.decodePlan(from: planJSON))
        XCTAssertEqual(plan2.blocks.count, 3)
    }
}

/// The background transport decodes and fails identically to the foreground one.
///
/// The first version of the background branch skipped HTTP status entirely, so a
/// 401 (bad key) and a 429 (rate limited) both surfaced as "Jeeves didn't return
/// a plan" — the diagnostics log is where that difference is supposed to live.
final class BackgroundTransportParityTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    func testAnApiErrorBodyIsRecognisedByShapeNotStatus() throws {
        let body = data("""
        {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
        """)
        let message = try XCTUnwrap(PlanGenerationService.apiErrorMessage(in: body))
        XCTAssertTrue(message.contains("authentication_error"), message)
        XCTAssertTrue(message.contains("invalid x-api-key"), message)
    }

    func testRateLimitingIsDistinguishableFromAnEmptyPlan() throws {
        let body = data("""
        {"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}
        """)
        let message = try XCTUnwrap(PlanGenerationService.apiErrorMessage(in: body))
        XCTAssertTrue(message.contains("rate_limit_error"), message)
    }

    /// A real plan response must NOT be mistaken for an error.
    func testASuccessfulBodyCarriesNoError() {
        let body = data("""
        {"type":"message","content":[{"type":"text","text":"{\\"blocks\\":[]}"}]}
        """)
        XCTAssertNil(PlanGenerationService.apiErrorMessage(in: body))
    }

    func testGarbageIsNotAnApiError() {
        XCTAssertNil(PlanGenerationService.apiErrorMessage(in: data("not json")))
        XCTAssertNil(PlanGenerationService.apiErrorMessage(in: Data()))
    }

    /// One decode entry point, so a plan delivered to a relaunched process is
    /// read exactly as one delivered to a live screen.
    func testTheSharedDecodeMatchesTheForegroundPath() {
        let body = data("""
        {"type":"message","content":[{"type":"text","text":"{\\"blocks\\":[{\\"title\\":\\"Chores\\",\\"startTime\\":\\"08:00\\",\\"endTime\\":\\"08:40\\",\\"note\\":null,\\"isAnchor\\":false,\\"kind\\":\\"activity\\"}],\\"dropped\\":[],\\"shrunk\\":[],\\"summary\\":\\"x\\",\\"boundaryTime\\":null}"}]}
        """)
        let viaShared = PlanGenerationService.plan(fromResponse: body)
        let viaParts = PlanGenerationService.extractText(from: body)
            .flatMap { PlanGenerationService.decodePlan(from: $0) }
        XCTAssertEqual(viaShared?.blocks.count, 1)
        XCTAssertEqual(viaShared?.blocks.count, viaParts?.blocks.count)
    }
}
