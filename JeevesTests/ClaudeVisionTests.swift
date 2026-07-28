//
//  ClaudeVisionTests.swift
//  JeevesTests
//
//  Exercises ClaudeVisionService.parse against real Anthropic Messages-API
//  response shapes — plain JSON text, ```json-fenced text, "nothing detected",
//  missing optional fields, an API error body, no text block, and malformed
//  book JSON — with no API key and no network. This is the self-test for the
//  bookshelf-scan parse path: run it instead of round-tripping through the phone.
//

import XCTest
@testable import Jeeves

final class ClaudeVisionTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    /// Wraps an assistant text string in the exact envelope the Anthropic
    /// Messages API returns (a `content` array with a `text` block). Using
    /// JSONSerialization escapes the inner JSON correctly, the same way the
    /// real API does when it puts a JSON string inside the `text` field.
    private func anthropicResponse(text: String) -> Data {
        let obj: [String: Any] = [
            "id": "msg_01ABC",
            "type": "message",
            "role": "assistant",
            "model": "claude-sonnet-5",
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 1200, "output_tokens": 90],
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - Happy path

    func testParsesPlainJSONBookArray() {
        let response = anthropicResponse(text: """
        [
          {"title": "Dune", "author": "Frank Herbert", "genre": "Science Fiction", "isFiction": true},
          {"title": "Sapiens", "author": "Yuval Noah Harari", "genre": "History", "isFiction": false}
        ]
        """)
        let books = ClaudeVisionService.parse(response)

        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(books[0].title, "Dune")
        XCTAssertEqual(books[0].author, "Frank Herbert")
        XCTAssertEqual(books[0].genre, "Science Fiction")
        XCTAssertEqual(books[0].isFiction, true)
        XCTAssertEqual(books[1].title, "Sapiens")
        XCTAssertEqual(books[1].isFiction, false)
        // id is derived from title + author.
        XCTAssertEqual(books[0].id, "DuneFrank Herbert")
    }

    /// Claude often wraps JSON in a ```json fence despite being told not to;
    /// parse must strip the fence and still decode.
    func testParsesFencedJSON() {
        let response = anthropicResponse(text: """
        ```json
        [{"title": "The Pragmatic Programmer", "author": "Andy Hunt", "genre": "Tech", "isFiction": false}]
        ```
        """)
        let books = ClaudeVisionService.parse(response)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "The Pragmatic Programmer")
        XCTAssertEqual(books[0].author, "Andy Hunt")
        XCTAssertEqual(books[0].isFiction, false)
    }

    /// Optional fields (genre, isFiction) may be omitted entirely by the model.
    func testMissingOptionalFieldsDecodeAsNil() {
        let response = anthropicResponse(text: """
        [{"title": "Untitled Poems", "author": "Anon"}]
        """)
        let books = ClaudeVisionService.parse(response)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "Untitled Poems")
        XCTAssertNil(books[0].genre)
        XCTAssertNil(books[0].isFiction)
    }

    /// Explicit nulls for the optionals must also decode (not throw).
    func testExplicitNullOptionals() {
        let response = anthropicResponse(text: """
        [{"title": "Mystery", "author": "Unknown", "genre": null, "isFiction": null}]
        """)
        let books = ClaudeVisionService.parse(response)
        XCTAssertEqual(books.count, 1)
        XCTAssertNil(books[0].genre)
        XCTAssertNil(books[0].isFiction)
    }

    // MARK: - Nothing detected

    /// An empty bookshelf → the model returns `[]`. That's a valid, non-error
    /// "nothing detected" result: an empty array, not a failure.
    func testNothingDetectedEmptyArray() {
        let response = anthropicResponse(text: "[]")
        XCTAssertTrue(ClaudeVisionService.parse(response).isEmpty)
    }

    // MARK: - Failure modes (all yield [], never throw)

    /// Anthropic error envelope (e.g. bad API key) — has an `error` object and
    /// no `content` array, so the MessageResponse decode fails → [].
    func testAPIErrorBodyYieldsEmpty() {
        let errorBody = data("""
        {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}
        """)
        XCTAssertTrue(ClaudeVisionService.parse(errorBody).isEmpty)
    }

    /// A well-formed response that contains no text block (e.g. only a
    /// thinking / tool_use block) → nothing to decode → [].
    func testNoTextBlockYieldsEmpty() {
        let response = data("""
        {"content": [{"type": "thinking", "text": null}]}
        """)
        XCTAssertTrue(ClaudeVisionService.parse(response).isEmpty)
    }

    /// A text block whose contents aren't a valid book array → [].
    func testMalformedBookJSONYieldsEmpty() {
        // Truncated / broken JSON inside an otherwise valid envelope.
        let response = anthropicResponse(text: "[{\"title\": \"Dune\", \"author\":")
        XCTAssertTrue(ClaudeVisionService.parse(response).isEmpty)
    }

    /// Prose instead of JSON (model ignored the format instruction) → [].
    func testProseInsteadOfJSONYieldsEmpty() {
        let response = anthropicResponse(text: "I can see a few books but the spines are too blurry to read.")
        XCTAssertTrue(ClaudeVisionService.parse(response).isEmpty)
    }

    /// Completely non-JSON bytes → [] (no crash).
    func testGarbageYieldsEmpty() {
        XCTAssertTrue(ClaudeVisionService.parse(data("not json at all")).isEmpty)
        XCTAssertTrue(ClaudeVisionService.parse(Data()).isEmpty)
    }
}
