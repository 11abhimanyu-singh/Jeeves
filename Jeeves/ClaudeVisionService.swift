//
//  ClaudeVisionService.swift
//  Jeeves
//
//  Sends a bookshelf photo to the Claude API and parses the model's
//  structured guess at each book's title, author, genre, and fiction/
//  non-fiction classification. Nothing gets saved until the user reviews
//  and confirms the results in the Library's scan-review screen.
//

import UIKit

struct DetectedBook: Decodable, Identifiable {
    var id: String { title + author }
    let title: String
    let author: String
    let genre: String?
    let isFiction: Bool?
}

enum ClaudeVisionError: LocalizedError {
    case missingAPIKey
    case imageEncodingFailed
    case requestFailed(String)
    case emptyResponse
    case unparsableResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add your Anthropic API key in Library Settings first."
        case .imageEncodingFailed: return "Couldn't process that photo."
        case .requestFailed(let message): return message
        case .emptyResponse: return "Claude didn't return anything usable."
        case .unparsableResponse: return "Couldn't read Claude's response as a book list."
        }
    }
}

enum ClaudeVisionService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-5"

    static func detectBooks(in image: UIImage) async throws -> [DetectedBook] {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw ClaudeVisionError.missingAPIKey
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else {
            throw ClaudeVisionError.imageEncodingFailed
        }
        let base64 = jpeg.base64EncodedString()

        let prompt = """
        Look at this photo of a bookshelf. Identify every individual book you can \
        make out. For each one, extract its title and author from the spine or \
        cover, and infer its genre and whether it's fiction or non-fiction.

        Respond with ONLY a JSON array, no prose, no markdown code fences. Each \
        element must look exactly like this:
        {"title": "...", "author": "...", "genre": "...", "isFiction": true}

        If you can't confidently read a book's title or author, skip it rather \
        than guessing wildly.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64,
                            ],
                        ],
                        ["type": "text", "text": prompt],
                    ],
                ]
            ],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeVisionError.requestFailed("No response from server.")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw ClaudeVisionError.requestFailed(message ?? "Request failed (\(http.statusCode)).")
        }

        struct MessageResponse: Decodable {
            struct ContentBlock: Decodable { let type: String; let text: String? }
            let content: [ContentBlock]
        }

        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text, !text.isEmpty else {
            throw ClaudeVisionError.emptyResponse
        }

        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleaned.data(using: .utf8),
              let books = try? JSONDecoder().decode([DetectedBook].self, from: jsonData) else {
            throw ClaudeVisionError.unparsableResponse
        }
        return books
    }
}
