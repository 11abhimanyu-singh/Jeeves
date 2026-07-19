//
//  EventVisionService.swift
//  Jeeves
//
//  Ticket-screenshot ingestion (PRD §5.5.2, §8): send an arbitrary ticket
//  image (BookMyShow-style and others) to Claude's vision API and extract
//  the event's title, date, time, and venue. Handles arbitrary layouts
//  because it's Claude reading the image, not hardcoded parsing. The result
//  pre-fills an event the user then reviews and confirms — nothing is saved
//  automatically.
//

import UIKit

struct DetectedEvent: Decodable {
    let title: String
    let date: String?        // "YYYY-MM-DD" if visible
    let startTime: String?   // "HH:MM" 24-hour if visible
    let endTime: String?     // "HH:MM" if visible/derivable
    let venue: String?       // venue name and/or address
}

enum EventVisionService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-5"

    static func detectEvent(in image: UIImage) async throws -> DetectedEvent {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw ClaudeVisionError.missingAPIKey
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else {
            throw ClaudeVisionError.imageEncodingFailed
        }
        let base64 = jpeg.base64EncodedString()

        let prompt = """
        \(JeevesChatService.dateContext())

        This is a screenshot of an event ticket or booking (a movie, concert, show, \
        reservation, etc.) — it may list several bookings on different dates. Extract \
        the ONE event happening on today's date (the current date above). If none is \
        on today's date, extract the soonest upcoming one. Respond with ONLY a JSON \
        object, no prose, no markdown fences:
        {"title": "...", "date": "YYYY-MM-DD", "startTime": "HH:MM", "endTime": "HH:MM", "venue": "venue name and/or address"}
        Use 24-hour time. If the end time isn't shown, estimate a sensible one from the \
        event type (e.g. ~3h for a movie/show) or use null. Use null for any field you \
        truly can't determine. Don't invent a venue address that isn't there — the venue name alone is fine.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
                    ["type": "text", "text": prompt],
                ],
            ]],
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
              let event = try? JSONDecoder().decode(DetectedEvent.self, from: jsonData) else {
            throw ClaudeVisionError.unparsableResponse
        }
        return event
    }
}
