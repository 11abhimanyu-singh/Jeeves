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

    /// Title+author duplicate check, case- and whitespace-insensitive.
    /// `excluding` lets an edit of an existing book not match itself.
    static func isDuplicate(title: String, author: String, in books: [Book], excluding: UUID? = nil) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let a = author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        return books.contains {
            $0.id != excluding
                && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == t
                && $0.author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == a
        }
    }
}
