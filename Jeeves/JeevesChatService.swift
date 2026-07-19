//
//  JeevesChatService.swift
//  Jeeves
//
//  Multi-turn chat with the Claude API — the proof-of-concept loop for the
//  Jeeves conversational agent (PRD §5.6, §9 step 3: "prove the loop: user
//  message → API → response rendered, with session history"). Plan
//  generation, chaining logic, and structured schedule output are later
//  phases; right now this just talks.
//

import Foundation

struct ChatMessage: Identifiable {
    enum Role: String { case user, assistant }
    let id = UUID()
    let role: Role
    let content: String
    // When set, this message renders as a plan timeline instead of a text
    // bubble. isOfflinePlan marks a deterministic-fallback plan.
    var plan: GeneratedPlan? = nil
    var isOfflinePlan: Bool = false
}

enum JeevesChatError: LocalizedError {
    case missingAPIKey
    case requestFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add your Anthropic API key in Library → Settings first."
        case .requestFailed(let message): return message
        case .emptyResponse: return "Jeeves didn't say anything back."
        }
    }
}

enum JeevesChatService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-5"

    private static let systemPrompt = """
    You are Jeeves, a personal day-planning assistant living inside the user's own \
    iOS productivity app. Have a natural, helpful conversation about their day and \
    plans. The app CAN build a full structured schedule with real commute times — \
    that happens when the user taps the "Plan my day" button (which also reads \
    whatever they've typed). So if someone describes their day or asks you to plan \
    it, don't say you're unable to; instead help them think it through and point \
    them to "Plan my day" to generate the actual schedule. Keep replies \
    conversational and reasonably brief, in the voice of a sharp, warm assistant.
    """

    /// `history` is every prior turn in the session (stateless API — the app is
    /// responsible for resending context each call, per PRD §5.6).
    static func send(history: [ChatMessage], newMessage: String) async throws -> String {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw JeevesChatError.missingAPIKey
        }

        var messages = history.map { ["role": $0.role.rawValue, "content": $0.content] }
        messages.append(["role": "user", "content": newMessage])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": messages,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw JeevesChatError.requestFailed("No response from server.")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw JeevesChatError.requestFailed(message ?? "Request failed (\(http.statusCode)).")
        }

        struct MessageResponse: Decodable {
            struct ContentBlock: Decodable { let type: String; let text: String? }
            let content: [ContentBlock]
        }

        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text, !text.isEmpty else {
            throw JeevesChatError.emptyResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
