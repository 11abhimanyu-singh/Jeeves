//
//  OpenAIJudgeTests.swift
//  JeevesTests
//
//  Exercises OpenAIJudgeService.parse against real OpenAI chat-completions
//  payload shapes — a plain Verdict object, a ```json-fenced object, empty
//  choices, missing content, an API error body, and a malformed Verdict — with
//  no key and no network. This is the self-test for judge-verdict parsing: run
//  it instead of round-tripping through OpenAI.
//

import XCTest
@testable import Jeeves

final class OpenAIJudgeTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    /// Wraps a model `content` string in a realistic OpenAI chat-completions
    /// envelope (choices[0].message.content). JSONSerialization handles the
    /// escaping, so the embedded content is quoted/escaped exactly as the API
    /// would return it.
    private func envelope(content: String) -> Data {
        let obj: [String: Any] = [
            "id": "chatcmpl-9xJ2sVQh7",
            "object": "chat.completion",
            "created": 1_753_600_000,
            "model": "gpt-5-mini",
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": content],
                "finish_reason": "stop",
            ]],
            "usage": ["prompt_tokens": 742, "completion_tokens": 96, "total_tokens": 838],
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    /// The JSON the judge is instructed to emit: overall + four sub-scores + reasoning.
    private let verdictJSON = """
    {"overall":0.85,"priorities":0.9,"fullDay":0.8,"chaining":0.75,"coherence":0.95,\
    "reasoning":"Lunch at 13:00 sits inside the window and the gym sub-blocks stay contiguous; \
    Reading was sensibly dropped once the afternoon event filled the day."}
    """

    // MARK: Happy path

    func testParsesValidVerdictContent() throws {
        let verdict = try XCTUnwrap(OpenAIJudgeService.parse(envelope(content: verdictJSON)))
        XCTAssertEqual(verdict.overall,    0.85, accuracy: 0.0001)
        XCTAssertEqual(verdict.priorities, 0.90, accuracy: 0.0001)
        XCTAssertEqual(verdict.fullDay,    0.80, accuracy: 0.0001)
        XCTAssertEqual(verdict.chaining,   0.75, accuracy: 0.0001)
        XCTAssertEqual(verdict.coherence,  0.95, accuracy: 0.0001)
        XCTAssertFalse(verdict.reasoning.isEmpty)
    }

    /// The historical break: a model wraps its JSON in a ```json fence even under
    /// json_object mode. The old inline decode fed the fence straight to the
    /// decoder and threw .unparsable; parse() now strips it and the scores parse.
    func testParsesVerdictFencedInJSONCodeBlock() throws {
        let fenced = "```json\n\(verdictJSON)\n```"
        let verdict = try XCTUnwrap(OpenAIJudgeService.parse(envelope(content: fenced)),
                                    "a ```json-fenced verdict body must still parse")
        XCTAssertEqual(verdict.overall,   0.85, accuracy: 0.0001)
        XCTAssertEqual(verdict.coherence, 0.95, accuracy: 0.0001)
    }

    /// Plain triple-backtick fence with no language tag also decodes.
    func testParsesVerdictFencedWithoutLanguageTag() throws {
        let fenced = "```\n\(verdictJSON)\n```"
        let verdict = try XCTUnwrap(OpenAIJudgeService.parse(envelope(content: fenced)))
        XCTAssertEqual(verdict.overall, 0.85, accuracy: 0.0001)
    }

    // MARK: Edge cases that break parsing

    func testEmptyChoicesReturnsNil() {
        // A 200 body with an empty choices array (no verdict to read).
        let json = #"{"id":"chatcmpl-x","object":"chat.completion","created":1753600000,"model":"gpt-5-mini","choices":[]}"#
        XCTAssertNil(OpenAIJudgeService.parse(data(json)))
    }

    func testMissingContentReturnsNil() {
        // The message carries no `content` (e.g. a refusal / tool call slot instead).
        let json = #"{"choices":[{"index":0,"message":{"role":"assistant"},"finish_reason":"stop"}]}"#
        XCTAssertNil(OpenAIJudgeService.parse(data(json)))
    }

    func testApiErrorBodyReturnsNil() {
        // The 4xx error envelope OpenAI returns — no `choices` key at all.
        let json = #"""
        {"error":{"message":"Incorrect API key provided.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}
        """#
        XCTAssertNil(OpenAIJudgeService.parse(data(json)))
    }

    func testMalformedVerdictContentReturnsNil() {
        // Valid envelope, but the content JSON is missing required sub-scores,
        // so Verdict cannot decode.
        let bad = #"{"overall":0.7,"reasoning":"missing priorities/fullDay/chaining/coherence"}"#
        XCTAssertNil(OpenAIJudgeService.parse(envelope(content: bad)))
    }

    func testContentIsNotJSONReturnsNil() {
        // The model answered in prose instead of JSON.
        XCTAssertNil(OpenAIJudgeService.parse(envelope(content: "Sorry, I can't score this plan.")))
    }

    func testJunkPayloadReturnsNil() {
        XCTAssertNil(OpenAIJudgeService.parse(data("not json at all")))
        XCTAssertNil(OpenAIJudgeService.parse(Data()))
    }
}
