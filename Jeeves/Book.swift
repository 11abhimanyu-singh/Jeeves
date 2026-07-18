//
//  Book.swift
//  Jeeves
//
//  SwiftData models for the reading library: books plus per-day page logs
//  used to track progress against the daily reading target.
//

import Foundation
import SwiftData

/// Whether the book is owned or just something you want. Independent of
/// reading progress — a Wishlist book and an Owned book can both be Unread.
enum LibraryStatus: String, Codable, CaseIterable {
    case wishlist = "Wishlist"
    case owned = "Owned"
}

/// Reading progress. Ingestion doesn't touch this — everything comes in as
/// Unread and gets triaged afterward.
enum ReadingStatus: String, Codable, CaseIterable {
    case unread = "Unread"
    case currentlyReading = "Currently Reading"
    case finished = "Read"
    case abandoned = "Abandoned"
}

enum BookRating: String, Codable, CaseIterable {
    case loved = "Loved"
    case liked = "Liked"
    case neutral = "Neutral"
    case disliked = "Disliked"
}

@Model
final class Book {
    var id: UUID
    var title: String
    var author: String
    var genre: String?
    var isFiction: Bool?
    var libraryStatus: LibraryStatus
    var status: ReadingStatus
    var rating: BookRating?
    var totalPages: Int?
    var currentPage: Int
    var dateAdded: Date
    var dateFinished: Date?
    var isbn: String?
    var thumbnailURLString: String?
    // The actual cover image bytes, downloaded once and kept — without this,
    // every row render re-fetches the image over the network (AsyncImage has
    // no persistent cache), which is wasted data on every scroll/relaunch.
    // thumbnailURLString is kept too, purely as the source to (re-)download from.
    @Attribute(.externalStorage) var thumbnailData: Data?
    var summary: String? // cached Claude-generated summary/review, fetched on demand

    init(
        title: String,
        author: String,
        genre: String? = nil,
        isFiction: Bool? = nil,
        libraryStatus: LibraryStatus = .owned,
        status: ReadingStatus = .unread,
        rating: BookRating? = nil,
        totalPages: Int? = nil,
        currentPage: Int = 0,
        dateAdded: Date = .now,
        dateFinished: Date? = nil,
        isbn: String? = nil,
        thumbnailURLString: String? = nil,
        thumbnailData: Data? = nil,
        summary: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.genre = genre
        self.isFiction = isFiction
        self.libraryStatus = libraryStatus
        self.status = status
        self.rating = rating
        self.totalPages = totalPages
        self.currentPage = currentPage
        self.dateAdded = dateAdded
        self.dateFinished = dateFinished
        self.isbn = isbn
        self.thumbnailURLString = thumbnailURLString
        self.thumbnailData = thumbnailData
        self.summary = summary
    }
}

/// One day's page-count entry against a book — lets the library check whether
/// today's reading target has been hit, the same way PrepSession/LeisureLog
/// let the day planner check completion.
@Model
final class ReadingLog {
    var date: Date          // startOfDay
    var bookID: UUID
    var pagesRead: Int

    init(date: Date, bookID: UUID, pagesRead: Int) {
        self.date = date
        self.bookID = bookID
        self.pagesRead = pagesRead
    }
}
