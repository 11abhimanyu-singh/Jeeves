//
//  OpenAIPlanService.swift
//  Jeeves
//
//  The same plan contract, asked of a different provider.
//
//  This exists to be MEASURED, not yet to be relied on. Nothing in the app calls
//  it: PlanCoordinator still falls straight from a Claude failure to the
//  deterministic engine. Whether a second provider earns a place in that path is
//  a decision for the numbers, and the numbers do not exist yet.
//
//  What makes this cheap is that the prompt was already provider-agnostic.
//  `PlanGenerationService.planningRules` and `.userPrompt` are plain text with no
//  Anthropic structure in them, and `decodePlan` already strips code fences and
//  decodes the shared contract. Only the envelope differs — Anthropic returns
//  content blocks, OpenAI returns choices — so that is the only thing this file
//  adds. Duplicating the prompt or the decoder would have been the mistake.
//

import Foundation

enum OpenAIPlanError: LocalizedError {
    case missingKey
    case requestFailed(String)
    case unparsableResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:            return "Add your OpenAI API key in Library → Settings first."
        case .requestFailed(let m):  return m
        case .unparsableResponse:    return "OpenAI's reply wasn't a readable plan."
        }
    }
}

enum OpenAIPlanService {
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// The identifier already proven against this exact task: tools/plan-eval.py
    /// judges plans with it. Not guessed — a wrong model string is a 404 at the
    /// worst possible moment.
    static let model = "gpt-5.6-terra"

    /// A plan for the same request the Anthropic path would receive.
    ///
    /// Takes the prompt pieces as parameters rather than rebuilding them, so a
    /// benchmark can prove both providers saw a byte-identical prompt — the only
    /// way the comparison means anything.
    static func generate(systemRules: String, userPrompt: String) async throws -> GeneratedPlan {
        guard let key = KeychainService.resolveOpenAIAPIKey(), !key.isEmpty else {
            throw OpenAIPlanError.missingKey
        }

        let body: [String: Any] = [
            "model": model,
            // A REASONING model spends budget before it writes anything. Probing
            // this endpoint with a 1-token ceiling came back 400: "Could not
            // finish the message because max_tokens or model output limit was
            // reached." Left unset, a default ceiling could be consumed by
            // reasoning and return an empty plan — and the benchmark would have
            // measured a truncation and called it a worse provider. Matched to
            // the Anthropic path's 16000 so both have the same room.
            "max_completion_tokens": 16000,
            // The contract is strict JSON, and this is the provider's own way of
            // holding the model to it. Note the response still goes through
            // decodePlan: json_object guarantees valid JSON, not the right SHAPE.
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemRules],
                ["role": "user", "content": userPrompt],
            ],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Matched to the Anthropic path (180s), not to the judge's 60s. A plan is
        // a far longer generation than a verdict, and a timeout mismatch would
        // make the comparison measure the timeout rather than the provider.
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIPlanError.requestFailed("No response from OpenAI.")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw OpenAIPlanError.requestFailed(
                "HTTP \(http.statusCode)" + (message.map { ": \($0)" } ?? ""))
        }

        guard let plan = parse(data) else { throw OpenAIPlanError.unparsableResponse }
        return plan
    }

    /// Envelope → plan. Pure and separate so it is testable without a key or a
    /// network, the same split OpenAIJudgeService uses.
    ///
    /// The ONLY OpenAI-specific step is reaching into `choices[0].message.content`;
    /// everything after that is the shared decoder, so a plan from either provider
    /// is read by identical code.
    static func parse(_ data: Data) -> GeneratedPlan? {
        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let text = decoded.choices.first?.message.content, !text.isEmpty
        else { return nil }
        return PlanGenerationService.decodePlan(from: text)
    }
}
