//
//  ClaudeTextServiceTests.swift
//  JeevesTests
//
//  Exercises ClaudeTextService.parse against real Anthropic Messages-API
//  response shapes — a normal text turn, a tool_use-only turn, empty content,
//  and a text block with no `text` field — with no API key and no network.
//  This is the self-test for the book-summary text call: run it instead of
//  round-tripping through the phone.
//

import XCTest
@testable import Jeeves

final class ClaudeTextServiceTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    /// Build a realistic /v1/messages response envelope wrapping `content`.
    private func response(content: String) -> Data {
        data("""
        {
          "id": "msg_01XFDUDYQ1nQ2fY7z8w9",
          "type": "message",
          "role": "assistant",
          "model": "claude-sonnet-5",
          "content": \(content),
          "stop_reason": "end_turn",
          "stop_sequence": null,
          "usage": {"input_tokens": 42, "output_tokens": 88}
        }
        """)
    }

    func testParsesTextAndTrimsWhitespace() {
        // The exact shape a normal text completion returns; note the leading/
        // trailing whitespace the model sometimes emits.
        let json = response(content: """
        [ {"type": "text", "text": "  A Tale of Two Cities is Dickens's 1859 novel set in London and Paris.\\n"} ]
        """)
        XCTAssertEqual(
            ClaudeTextService.parse(json),
            "A Tale of Two Cities is Dickens's 1859 novel set in London and Paris."
        )
    }

    func testPicksTextBlockEvenWhenPrecededByOtherBlocks() {
        // Multi-block turns must still surface the text block, not the first block.
        let json = response(content: """
        [ {"type": "tool_use", "id": "toolu_01A", "name": "lookup", "input": {}},
          {"type": "text", "text": "Here is the summary."} ]
        """)
        XCTAssertEqual(ClaudeTextService.parse(json), "Here is the summary.")
    }

    func testToolUseOnlyResponseYieldsNil() {
        // A turn that stopped at a tool call carries no text block → nil.
        let json = response(content: """
        [ {"type": "tool_use", "id": "toolu_01B", "name": "lookup", "input": {"q": "dickens"}} ]
        """)
        XCTAssertNil(ClaudeTextService.parse(json))
    }

    func testEmptyContentYieldsNil() {
        XCTAssertNil(ClaudeTextService.parse(response(content: "[]")))
    }

    func testTextBlockWithMissingTextFieldYieldsNil() {
        // type is "text" but the `text` key is absent → treated as no text.
        let json = response(content: """
        [ {"type": "text"} ]
        """)
        XCTAssertNil(ClaudeTextService.parse(json))
    }

    func testEmptyStringTextYieldsNil() {
        let json = response(content: """
        [ {"type": "text", "text": ""} ]
        """)
        XCTAssertNil(ClaudeTextService.parse(json))
    }

    func testApiErrorBodyYieldsNil() {
        // An error envelope (rate limit etc.) has no `content` → parse must not
        // crash and must return nil rather than throw.
        let json = data("""
        {"type": "error", "error": {"type": "rate_limit_error", "message": "Overloaded"}}
        """)
        XCTAssertNil(ClaudeTextService.parse(json))
    }

    func testJunkYieldsNil() {
        XCTAssertNil(ClaudeTextService.parse(data("not json")))
    }
}
