//
//  BookSearchService.swift
//  Jeeves
//
//  Free-text book search via the Open Library API (no key), used by the
//  "Add Books" page as a third ingestion path alongside shelf-photo scans
//  and manual entry.
//

import Foundation

struct BookSearchResult: Identifiable {
    var id: String { (isbn ?? "") + title + author }
    let title: String
    let author: String
    let isbn: String?
    let thumbnailURLString: String?
}

enum BookSearchService {
    private struct Response: Decodable {
        struct Doc: Decodable {
            let title: String?
            let authorName: [String]?
            let isbn: [String]?
            let coverID: Int?

            enum CodingKeys: String, CodingKey {
                case title
                case authorName = "author_name"
                case isbn
                case coverID = "cover_i"
            }
        }
        let docs: [Doc]
    }

    static func search(query: String) async -> [BookSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://openlibrary.org/search.json")
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "fields", value: "title,author_name,isbn,cover_i"),
        ]
        guard let url = components?.url else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.docs.compactMap { doc in
                guard let title = doc.title, let author = doc.authorName?.first else { return nil }
                let isbn = doc.isbn?.first { $0.count == 13 } ?? doc.isbn?.first
                let thumbnail = doc.coverID.map { "https://covers.openlibrary.org/b/id/\($0)-M.jpg" }
                return BookSearchResult(title: title, author: author, isbn: isbn, thumbnailURLString: thumbnail)
            }
        } catch {
            return []
        }
    }
}
