//
//  BookSearchService.swift
//  Jeeves
//
//  Free-text book search, used by the "Add Books" page as a third ingestion
//  path alongside shelf-photo scans and manual entry. Open Library (no key)
//  is tried first; if it returns nothing and a Google Books API key is
//  saved, that's tried as a fallback.
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
    static func search(query: String) async -> [BookSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let openLibraryResults = await searchOpenLibrary(query: trimmed)
        if !openLibraryResults.isEmpty { return openLibraryResults }
        return await searchGoogleBooks(query: trimmed)
    }

    // MARK: Open Library

    private struct OpenLibraryResponse: Decodable {
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

    private static func searchOpenLibrary(query: String) async -> [BookSearchResult] {
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "fields", value: "title,author_name,isbn,cover_i"),
        ]
        guard let url = components?.url else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(OpenLibraryResponse.self, from: data)
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

    // MARK: Google Books (fallback, requires a user-supplied key)

    private struct GoogleBooksResponse: Decodable {
        struct Item: Decodable {
            struct VolumeInfo: Decodable {
                struct Identifier: Decodable { let type: String; let identifier: String }
                struct ImageLinks: Decodable { let thumbnail: String? }
                let title: String?
                let authors: [String]?
                let industryIdentifiers: [Identifier]?
                let imageLinks: ImageLinks?
            }
            let volumeInfo: VolumeInfo
        }
        let items: [Item]?
    }

    private static func searchGoogleBooks(query: String) async -> [BookSearchResult] {
        guard let apiKey = KeychainService.loadGoogleBooksAPIKey(), !apiKey.isEmpty else { return [] }

        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "15"),
            URLQueryItem(name: "key", value: apiKey),
        ]
        guard let url = components?.url else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(GoogleBooksResponse.self, from: data)
            return (decoded.items ?? []).compactMap { item in
                let info = item.volumeInfo
                guard let title = info.title, let author = info.authors?.first else { return nil }
                let isbn = info.industryIdentifiers?.first { $0.type == "ISBN_13" }?.identifier
                    ?? info.industryIdentifiers?.first { $0.type == "ISBN_10" }?.identifier
                let thumbnail = info.imageLinks?.thumbnail?.replacingOccurrences(of: "http://", with: "https://")
                return BookSearchResult(title: title, author: author, isbn: isbn, thumbnailURLString: thumbnail)
            }
        } catch {
            return []
        }
    }
}
