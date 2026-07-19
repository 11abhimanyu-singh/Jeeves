//
//  LibraryLogic.swift
//  Jeeves
//
//  Pure library decision logic, kept out of the SwiftUI views so the unit
//  test target can exercise it directly (views can't be meaningfully
//  unit-tested; plain functions can).
//

import Foundation

enum LibraryLogic {
    /// Fiction/non-fiction alternating recommendation: prefer an unread book
    /// of the opposite kind from the last finished one, falling back to the
    /// first unread. Returns nil while anything is Currently Reading (no
    /// recommendation needed) or when nothing is unread.
    static func recommendedNext(unread: [Book], lastFinished: Book?, currentlyReadingCount: Int) -> Book? {
        guard currentlyReadingCount == 0, !unread.isEmpty else { return nil }
        if let wantFiction = lastFinished?.isFiction.map({ !$0 }),
           let match = unread.first(where: { $0.isFiction == wantFiction }) {
            return match
        }
        return unread.first
    }

    /// Fuzzy title+author duplicate check. Photographing the same book twice
    /// yields slightly different strings each scan ("Zero to One" vs "Zero to
    /// One: Notes on Startups", author with/without a co-author), so an exact
    /// match missed re-scans. This normalizes hard (drop subtitle, punctuation,
    /// diacritics, case, extra spaces) and matches authors loosely.
    /// `excluding` lets an edit of an existing book not match itself.
    static func isDuplicate(title: String, author: String, in books: [Book], excluding: UUID? = nil) -> Bool {
        let t = titleKey(title)
        guard !t.isEmpty else { return false }
        let a = normalize(author)
        return books.contains { book in
            guard book.id != excluding, titleKey(book.title) == t else { return false }
            let ba = normalize(book.author)
            // Authors match loosely: equal, one contains the other (co-authors,
            // "with X"), or one side blank (a scan that missed the author).
            if a.isEmpty || ba.isEmpty || a == ba { return true }
            return a.contains(ba) || ba.contains(a)
        }
    }

    /// Comparison key for a title: drop any subtitle after a colon (vision
    /// often returns the short title one scan, the full subtitle the next),
    /// then normalize.
    static func titleKey(_ title: String) -> String {
        let base = title.split(separator: ":", maxSplits: 1).first.map(String.init) ?? title
        return normalize(base)
    }

    /// Lowercase, strip diacritics and punctuation, collapse whitespace.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }
}
