//
//  ClaudeTextService.swift
//  Jeeves
//
//  One-shot text completion against the Claude API — used for the book
//  summary/review shown when you tap a cover thumbnail. Reuses the same
//  Keychain-stored API key as the shelf-scan feature.
//

import Foundation

enum ClaudeTextService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-5"

    static func bookSummary(title: String, author: String) async throws -> String {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw ClaudeVisionError.missingAPIKey
        }

        let prompt = """
        In 3-4 sentences, summarize the book "\(title)" by \(author) and give a brief \
        sense of its critical reception if you're aware of it. If you don't have \
        reliable knowledge of this specific book, say so plainly rather than guessing. \
        Plain text only — no markdown, no headers, no bullet points.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "messages": [["role": "user", "content": prompt]],
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

        guard let text = parse(data) else {
            throw ClaudeVisionError.emptyResponse
        }
        return text
    }

    /// Pure decode of an Anthropic Messages response down to the assistant's
    /// reply text. Extracted out of the network call so it can be unit-tested
    /// against real API payloads with no API key and no round-trip (the way
    /// GoogleCalendarService.parse is). Returns nil for a malformed, empty, or
    /// text-less response (e.g. a `tool_use`-only turn) — mirroring
    /// GoogleCalendarService.parse returning [] on bad input — and the caller
    /// maps that nil to `.emptyResponse`.
    static func parse(_ data: Data) -> String? {
        struct MessageResponse: Decodable {
            struct ContentBlock: Decodable { let type: String; let text: String? }
            let content: [ContentBlock]
        }
        guard let decoded = try? JSONDecoder().decode(MessageResponse.self, from: data),
              let text = decoded.content.first(where: { $0.type == "text" })?.text,
              !text.isEmpty else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
