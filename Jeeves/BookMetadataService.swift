//
//  BookMetadataService.swift
//  Jeeves
//
//  Looks up ISBN and a cover thumbnail for a book by title/author via the
//  Open Library API (no key, no quota — unlike the Google Books API, which
//  turned out to reject every anonymous request with a 429 in testing).
//  Best-effort — a miss (common for small regional presses) just leaves
//  those fields empty rather than blocking anything.
//

import Foundation

enum BookMetadataService {
    private struct SearchResponse: Decodable {
        struct Doc: Decodable {
            let isbn: [String]?
            let coverID: Int?

            enum CodingKeys: String, CodingKey {
                case isbn
                case coverID = "cover_i"
            }
        }
        let docs: [Doc]
    }

    static func fetch(title: String, author: String) async -> (isbn: String?, thumbnailURLString: String?) {
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "author", value: author),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fields", value: "isbn,cover_i"),
        ]
        guard let url = components?.url else { return (nil, nil) }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            guard let doc = decoded.docs.first else { return (nil, nil) }

            // Prefer a 13-digit ISBN if one's in the list, else take whatever's first.
            let isbn = doc.isbn?.first { $0.count == 13 } ?? doc.isbn?.first

            let thumbnail = doc.coverID.map { "https://covers.openlibrary.org/b/id/\($0)-M.jpg" }

            return (isbn, thumbnail)
        } catch {
            return (nil, nil)
        }
    }
}
