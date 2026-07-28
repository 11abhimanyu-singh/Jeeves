//
//  BookMetadataServiceTests.swift
//  JeevesTests
//
//  Exercises BookMetadataService.parse against real Open Library `search.json`
//  payload shapes for the metadata lookup (`fields=isbn,cover_i`, `limit=1`):
//  a normal single-doc result, a doc missing the cover, a doc missing the ISBN,
//  zero results, an error body, and junk — with no network. This is the
//  self-test for ISBN/cover backfill parsing.
//

import XCTest
@testable import Jeeves

final class BookMetadataServiceTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    /// A normal single-doc result. Verifies ISBN-13 preference and cover-URL
    /// construction from the first (and only) doc.
    func testParsesNormalResult() {
        let json = data("""
        {
          "numFound": 1,
          "start": 0,
          "docs": [
            { "isbn": ["054792822X", "9780547928227"], "cover_i": 8231856 }
          ]
        }
        """)
        let result = BookMetadataService.parse(json)

        // 13-digit ISBN preferred over the 10-digit listed first.
        XCTAssertEqual(result.isbn, "9780547928227")
        XCTAssertEqual(result.thumbnailURLString, "https://covers.openlibrary.org/b/id/8231856-M.jpg")
    }

    /// A doc with an ISBN but no cover → thumbnail nil, ISBN still returned.
    func testDocMissingCover() {
        let json = data("""
        { "docs": [ { "isbn": ["9780441013593"] } ] }
        """)
        let result = BookMetadataService.parse(json)
        XCTAssertEqual(result.isbn, "9780441013593")
        XCTAssertNil(result.thumbnailURLString, "no cover_i → no thumbnail URL")
    }

    /// A doc with a cover but no ISBN → ISBN nil, thumbnail still returned.
    func testDocMissingISBN() {
        let json = data("""
        { "docs": [ { "cover_i": 12345 } ] }
        """)
        let result = BookMetadataService.parse(json)
        XCTAssertNil(result.isbn, "no isbn field → nil")
        XCTAssertEqual(result.thumbnailURLString, "https://covers.openlibrary.org/b/id/12345-M.jpg")
    }

    /// Only a 10-digit ISBN present → the 13-digit preference falls back to it.
    func testTenDigitISBNFallback() {
        let json = data("""
        { "docs": [ { "isbn": ["0441013597"], "cover_i": 7 } ] }
        """)
        let result = BookMetadataService.parse(json)
        XCTAssertEqual(result.isbn, "0441013597")
    }

    /// Zero results, an error body, and junk all yield (nil, nil) without
    /// throwing or crashing.
    func testEmptyErrorAndJunkPayloads() {
        for body in ["{\"docs\":[]}", "{\"error\":\"invalid request\"}", "not json", ""] {
            let result = BookMetadataService.parse(data(body))
            XCTAssertNil(result.isbn, "\(body) → nil isbn")
            XCTAssertNil(result.thumbnailURLString, "\(body) → nil thumbnail")
        }
    }
}
