//
//  AnchorExtractionService.swift
//  Jeeves
//
//  Turns a natural-language planning message ("I have to go to MLR
//  Convention Centre at 7 pm, plan my day") into structured anchors — the
//  first step that makes conversational planning actually work (PRD §5.6).
//  Whatever it extracts becomes real DailyEvents / gym state, which the
//  planner then reasons over and routes with real Maps commute times.
//

import Foundation

struct ExtractedAnchors: Decodable {
    struct Event: Decodable {
        let title: String
        let startTime: String?   // "HH:MM" 24h
        let endTime: String?     // "HH:MM"
        let venue: String?       // place name or address — Maps can route to either
        let leavingFrom: String? // "Home" | "Work" | "Gym"
    }
    let events: [Event]
    let gymToday: Bool?
    let gymTime: String?         // "HH:MM"
}

enum AnchorExtractionService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-5"

    /// Extracts only anchors *newly mentioned* in `message` that aren't already
    /// among `existingTitles`. Returns empty anchors (not an error) if nothing
    /// planning-relevant is found, so a casual message doesn't create noise.
    static func extract(from message: String, existingTitles: [String]) async throws -> ExtractedAnchors {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw PlanGenerationError.missingAPIKey
        }

        let prompt = """
        The user said: "\(message)"

        Extract any events (appointments, shows, meetings, movies, etc.) and gym \
        plans they mention for TODAY. These already exist, so do NOT repeat them: \
        \(existingTitles.isEmpty ? "(none)" : existingTitles.joined(separator: "; ")).

        Respond with ONLY this JSON, nothing else:
        {"events": [{"title": "...", "startTime": "HH:MM", "endTime": "HH:MM", "venue": "place name or address", "leavingFrom": "Home"}], "gymToday": true, "gymTime": "HH:MM"}

        Rules:
        - 24-hour times. If an end time isn't given, estimate a sensible one from the event type (e.g. ~3h for a show) or use null.
        - venue: keep the place name as the user said it ("MLR Convention Centre") — do not invent an address.
        - leavingFrom: only if they say where they're heading out from; else "Home".
        - Only include gymToday/gymTime if the user actually mentions the gym; otherwise set both to null.
        - If the message mentions no events and no gym, return {"events": [], "gymToday": null, "gymTime": null}.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw PlanGenerationError.requestFailed(message ?? "Extraction request failed.")
        }

        struct MessageResponse: Decodable {
            struct ContentBlock: Decodable { let type: String; let text: String? }
            let content: [ContentBlock]
        }
        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text, !text.isEmpty else {
            throw PlanGenerationError.emptyResponse
        }

        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"), start < end {
            cleaned = String(cleaned[start...end])
        }
        guard let jsonData = cleaned.data(using: .utf8),
              let anchors = try? JSONDecoder().decode(ExtractedAnchors.self, from: jsonData) else {
            throw PlanGenerationError.unparsableResponse
        }
        return anchors
    }
}
