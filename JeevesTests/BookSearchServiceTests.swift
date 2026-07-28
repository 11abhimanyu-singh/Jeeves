//
//  BookSearchServiceTests.swift
//  JeevesTests
//
//  Exercises BookSearchService.parse against real Open Library `search.json`
//  payload shapes — a normal multi-doc result, docs missing optional fields
//  (no cover, no author, no title), zero results, an error body, and junk —
//  with no network. This is the self-test for free-text book search parsing:
//  run it instead of round-tripping through Open Library.
//

import XCTest
@testable import Jeeves

final class BookSearchServiceTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    /// A normal multi-doc result, including the fields Open Library actually
    /// returns for `fields=title,author_name,isbn,cover_i`. Verifies title,
    /// first author, ISBN-13 preference, and cover-URL construction.
    func testParsesNormalMultiDocResult() {
        let json = data("""
        {
          "numFound": 2,
          "start": 0,
          "numFoundExact": true,
          "docs": [
            {
              "title": "The Hobbit",
              "author_name": ["J.R.R. Tolkien", "Christopher Tolkien"],
              "isbn": ["054792822X", "9780547928227", "0261102214"],
              "cover_i": 8231856
            },
            {
              "title": "Dune",
              "author_name": ["Frank Herbert"],
              "isbn": ["9780441013593"],
              "cover_i": 11481354
            }
          ]
        }
        """)
        let results = BookSearchService.parse(json)

        XCTAssertEqual(results.count, 2)

        // Doc 1: multiple authors → first author is used; 13-digit ISBN preferred
        // over the 10-digit that appears earlier in the list.
        XCTAssertEqual(results[0].title, "The Hobbit")
        XCTAssertEqual(results[0].author, "J.R.R. Tolkien")
        XCTAssertEqual(results[0].isbn, "9780547928227")
        XCTAssertEqual(results[0].thumbnailURLString, "https://covers.openlibrary.org/b/id/8231856-M.jpg")

        // Doc 2: single author, single 13-digit ISBN.
        XCTAssertEqual(results[1].title, "Dune")
        XCTAssertEqual(results[1].author, "Frank Herbert")
        XCTAssertEqual(results[1].isbn, "9780441013593")
        XCTAssertEqual(results[1].thumbnailURLString, "https://covers.openlibrary.org/b/id/11481354-M.jpg")
    }

    /// Docs missing optional fields. A doc with a title + author but no cover
    /// is KEPT (thumbnail nil); docs with no author or no title are DROPPED,
    /// because there's nothing meaningful to show the user.
    func testMissingOptionalFields() {
        let json = data("""
        {
          "docs": [
            { "title": "The Left Hand of Darkness", "author_name": ["Ursula K. Le Guin"] },
            { "title": "Cover-only, no author", "cover_i": 42 },
            { "author_name": ["Nobody"], "cover_i": 99 },
            { "title": "Only ten-digit isbn", "author_name": ["Someone"], "isbn": ["0123456789"] }
          ]
        }
        """)
        let results = BookSearchService.parse(json)

        // Doc 1 (no cover, no isbn) and Doc 4 (10-digit isbn only) survive;
        // Doc 2 (no author) and Doc 3 (no title) are dropped.
        XCTAssertEqual(results.count, 2)

        XCTAssertEqual(results[0].title, "The Left Hand of Darkness")
        XCTAssertEqual(results[0].author, "Ursula K. Le Guin")
        XCTAssertNil(results[0].isbn, "no isbn field → nil")
        XCTAssertNil(results[0].thumbnailURLString, "no cover_i → no thumbnail URL")

        // No 13-digit ISBN present → falls back to whatever's first.
        XCTAssertEqual(results[1].title, "Only ten-digit isbn")
        XCTAssertEqual(results[1].isbn, "0123456789")
        XCTAssertNil(results[1].thumbnailURLString)
    }

    /// Zero results, an Open Library error body, and outright junk all yield
    /// an empty array rather than throwing or crashing.
    func testEmptyErrorAndJunkPayloads() {
        XCTAssertTrue(BookSearchService.parse(data("{\"docs\":[]}")).isEmpty, "zero results → empty")
        XCTAssertTrue(BookSearchService.parse(data("{\"error\":\"invalid request\"}")).isEmpty, "error body (no docs) → empty")
        XCTAssertTrue(BookSearchService.parse(data("not json")).isEmpty, "junk → empty")
        XCTAssertTrue(BookSearchService.parse(Data()).isEmpty, "empty body → empty")
    }
}
