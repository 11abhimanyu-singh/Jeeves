//
//  LibraryLogicTests.swift
//  JeevesTests
//
//  Guards the library's decision logic: the fiction/non-fiction alternating
//  recommendation and the title+author duplicate check.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class LibraryLogicTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(
            for: Book.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeBook(_ title: String, author: String = "Author", isFiction: Bool? = nil, status: ReadingStatus = .unread) -> Book {
        let book = Book(title: title, author: author, isFiction: isFiction, status: status)
        container.mainContext.insert(book)
        return book
    }

    // MARK: Recommendation

    func testNoRecommendationWhileSomethingIsBeingRead() {
        let unread = [makeBook("A", isFiction: true)]
        XCTAssertNil(LibraryLogic.recommendedNext(unread: unread, lastFinished: nil, currentlyReadingCount: 1))
    }

    func testNoRecommendationWhenNothingUnread() {
        XCTAssertNil(LibraryLogic.recommendedNext(unread: [], lastFinished: nil, currentlyReadingCount: 0))
    }

    func testAlternatesToNonFictionAfterFinishingFiction() {
        let fiction = makeBook("Fiction next", isFiction: true)
        let nonFiction = makeBook("Non-fiction next", isFiction: false)
        let lastFinished = makeBook("Done", isFiction: true, status: .finished)
        // Non-fiction is listed second, but must win because the last finish was fiction.
        let pick = LibraryLogic.recommendedNext(unread: [fiction, nonFiction], lastFinished: lastFinished, currentlyReadingCount: 0)
        XCTAssertEqual(pick?.title, nonFiction.title)
    }

    func testAlternatesToFictionAfterFinishingNonFiction() {
        let nonFiction = makeBook("Non-fiction next", isFiction: false)
        let fiction = makeBook("Fiction next", isFiction: true)
        let lastFinished = makeBook("Done", isFiction: false, status: .finished)
        let pick = LibraryLogic.recommendedNext(unread: [nonFiction, fiction], lastFinished: lastFinished, currentlyReadingCount: 0)
        XCTAssertEqual(pick?.title, fiction.title)
    }

    func testFallsBackToFirstUnreadWhenNoOppositeKindAvailable() {
        let a = makeBook("A", isFiction: true)
        let b = makeBook("B", isFiction: true)
        let lastFinished = makeBook("Done", isFiction: true, status: .finished)
        let pick = LibraryLogic.recommendedNext(unread: [a, b], lastFinished: lastFinished, currentlyReadingCount: 0)
        XCTAssertEqual(pick?.title, a.title)
    }

    func testFirstUnreadWhenNothingFinishedYet() {
        let a = makeBook("A", isFiction: false)
        let b = makeBook("B", isFiction: true)
        let pick = LibraryLogic.recommendedNext(unread: [a, b], lastFinished: nil, currentlyReadingCount: 0)
        XCTAssertEqual(pick?.title, a.title)
    }

    // MARK: Duplicate detection

    func testExactDuplicateIsCaught() {
        let books = [makeBook("The Living Elephants", author: "Sukumar")]
        XCTAssertTrue(LibraryLogic.isDuplicate(title: "The Living Elephants", author: "Sukumar", in: books))
    }

    func testDuplicateIsCaseAndWhitespaceInsensitive() {
        let books = [makeBook("The Living Elephants", author: "Sukumar")]
        XCTAssertTrue(LibraryLogic.isDuplicate(title: "  the living elephants ", author: "SUKUMAR", in: books))
    }

    func testSameTitleDifferentAuthorIsNotADuplicate() {
        let books = [makeBook("Wildlife", author: "Author One")]
        XCTAssertFalse(LibraryLogic.isDuplicate(title: "Wildlife", author: "Author Two", in: books))
    }

    func testEditingABookDoesNotMatchItself() {
        let book = makeBook("Nine Man-Eaters", author: "Kenneth Anderson")
        XCTAssertFalse(LibraryLogic.isDuplicate(title: "Nine Man-Eaters", author: "Kenneth Anderson", in: [book], excluding: book.id))
    }

    func testEmptyTitleIsNeverADuplicate() {
        let books = [makeBook("", author: "")]
        XCTAssertFalse(LibraryLogic.isDuplicate(title: "", author: "", in: books))
    }
}
