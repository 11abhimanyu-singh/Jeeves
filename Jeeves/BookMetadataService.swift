//
//  BookMetadataService.swift
//  Jeeves
//
//  Looks up ISBN and a cover thumbnail for a book by title/author. Google
//  Books is tried first when a key is saved (better cover art/metadata for
//  mainstream titles) — anonymous Google Books requests reliably return a
//  429 quota error, which is why a key is required for it at all, and why
//  it silently falls through to Open Library (no key, no quota) when no key
//  is set or Google has no match. Both are best-effort: a miss on both just
//  leaves the fields empty rather than blocking anything.
//

import Foundation

enum BookMetadataService {
    static func fetch(title: String, author: String) async -> (isbn: String?, thumbnailURLString: String?) {
        let googleResult = await fetchFromGoogleBooks(title: title, author: author)
        if googleResult.isbn != nil || googleResult.thumbnailURLString != nil {
            return googleResult
        }
        return await fetchFromOpenLibrary(title: title, author: author)
    }

    // MARK: Open Library

    private struct OpenLibraryResponse: Decodable {
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

    private static func fetchFromOpenLibrary(title: String, author: String) async -> (isbn: String?, thumbnailURLString: String?) {
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
            let decoded = try JSONDecoder().decode(OpenLibraryResponse.self, from: data)
            guard let doc = decoded.docs.first else { return (nil, nil) }

            // Prefer a 13-digit ISBN if one's in the list, else take whatever's first.
            let isbn = doc.isbn?.first { $0.count == 13 } ?? doc.isbn?.first
            let thumbnail = doc.coverID.map { "https://covers.openlibrary.org/b/id/\($0)-M.jpg" }
            return (isbn, thumbnail)
        } catch {
            return (nil, nil)
        }
    }

    // MARK: Google Books (fallback, requires a user-supplied key)

    private struct GoogleBooksResponse: Decodable {
        struct Item: Decodable {
            struct VolumeInfo: Decodable {
                struct Identifier: Decodable { let type: String; let identifier: String }
                struct ImageLinks: Decodable { let thumbnail: String? }
                let industryIdentifiers: [Identifier]?
                let imageLinks: ImageLinks?
            }
            let volumeInfo: VolumeInfo
        }
        let items: [Item]?
    }

    private static func fetchFromGoogleBooks(title: String, author: String) async -> (isbn: String?, thumbnailURLString: String?) {
        guard let apiKey = KeychainService.loadGoogleBooksAPIKey(), !apiKey.isEmpty else { return (nil, nil) }

        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "intitle:\(title) inauthor:\(author)"),
            URLQueryItem(name: "maxResults", value: "1"),
            URLQueryItem(name: "key", value: apiKey),
        ]
        guard let url = components?.url else { return (nil, nil) }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(GoogleBooksResponse.self, from: data)
            guard let info = decoded.items?.first?.volumeInfo else { return (nil, nil) }

            let isbn = info.industryIdentifiers?.first { $0.type == "ISBN_13" }?.identifier
                ?? info.industryIdentifiers?.first { $0.type == "ISBN_10" }?.identifier
            // Google serves these over plain http:// — upgrade so ATS doesn't block the load.
            let thumbnail = info.imageLinks?.thumbnail?.replacingOccurrences(of: "http://", with: "https://")
            return (isbn, thumbnail)
        } catch {
            return (nil, nil)
        }
    }
}
