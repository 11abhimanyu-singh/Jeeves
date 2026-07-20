//
//  OpenAIJudgeService.swift
//  Jeeves
//
//  An INDEPENDENT judge for plan evals: ChatGPT (OpenAI) scores a plan Claude
//  produced against the scheduler's rules. Using a different model family
//  avoids self-grading bias. This is eval-only — OpenAI never generates plans
//  (that's Claude); it only scores them. Raw REST, key stored in Keychain.
//

import Foundation

enum OpenAIJudgeError: LocalizedError {
    case missingKey
    case requestFailed(String)
    case unparsable

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add an OpenAI API key in Settings to run ChatGPT plan evals."
        case .requestFailed(let m): return m
        case .unparsable: return "Couldn't read ChatGPT's verdict."
        }
    }
}

enum OpenAIJudgeService {
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    // Configurable — any current chat model works as a judge.
    static let model = "gpt-4o"

    /// A 0–1 score per criterion plus an overall and the judge's reasoning.
    struct Verdict: Decodable {
        let overall: Double
        let priorities: Double   // respects Must-do / correct drop order
        let fullDay: Double      // uses the whole 08:00–20:30 window; no wasted afternoon
        let chaining: Double     // chains trips, uses on-site facilities sensibly
        let coherence: Double    // chronological, realistic durations, no cramming
        let reasoning: String
    }

    static func judge(plan: GeneratedPlan, scenario: String) async throws -> Verdict {
        guard let key = KeychainService.loadOpenAIAPIKey(), !key.isEmpty else {
            throw OpenAIJudgeError.missingKey
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt(plan: plan, scenario: scenario)],
            ],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIJudgeError.requestFailed("No response from OpenAI.")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw OpenAIJudgeError.requestFailed(message ?? "OpenAI request failed (\(http.statusCode)).")
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
            let choices: [Choice]
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = decoded.choices.first?.message.content,
              let verdictData = content.data(using: .utf8),
              let verdict = try? JSONDecoder().decode(Verdict.self, from: verdictData) else {
            throw OpenAIJudgeError.unparsable
        }
        return verdict
    }

    // MARK: Prompt

    private static let systemPrompt = """
    You are an impartial evaluator of daily schedules produced by another AI assistant. \
    You did NOT write the plan; your job is only to score it against the rules below. \
    Be strict and specific. Respond with ONLY a JSON object, no prose outside it.
    """

    private static func userPrompt(plan: GeneratedPlan, scenario: String) -> String {
        var s = "SCENARIO:\n\(scenario)\n\n"
        s += "THE SCHEDULER'S RULES:\n"
        s += "- Productive window is 08:00–20:30 every day. Interview prep — Reading (90 min) is a Must-do at the 08:00 peak slot; Lunch is a Must-do by 14:30. Must-dos are NEVER dropped.\n"
        s += "- Events (appointments, shows) are fixed anchors you work AROUND — leave, attend, return home — and the day continues after you return, up to 20:30. A midday event must NOT cause the afternoon to be discarded.\n"
        s += "- Drop order when the day is full: Flexible first, then Important, never Must-do. Better to shrink than drop; report drops/shrinks.\n"
        s += "- Reason like a human: chain adjacent trips (gym→event directly), use on-site facilities (shower at gym before an event), relocate flexible activities sensibly.\n\n"
        s += "THE PLAN TO SCORE:\n"
        for b in plan.blocks {
            s += "- \(b.startTime)–\(b.endTime) \(b.title) [\(b.kind)]\(b.note.map { " — \($0)" } ?? "")\n"
        }
        if !plan.dropped.isEmpty { s += "DROPPED: \(plan.dropped.joined(separator: ", "))\n" }
        if !plan.shrunk.isEmpty { s += "SHRUNK: \(plan.shrunk.joined(separator: ", "))\n" }
        s += "SUMMARY: \(plan.summary)\n\n"
        s += """
        Score each criterion from 0.0 (bad) to 1.0 (perfect) and give an overall 0.0–1.0. Return EXACTLY:
        {
          "overall": 0.0,
          "priorities": 0.0,
          "fullDay": 0.0,
          "chaining": 0.0,
          "coherence": 0.0,
          "reasoning": "2-4 sentences citing specific blocks/decisions that raised or lowered the score."
        }
        priorities = respects Must-dos and correct drop order. fullDay = uses the whole window, no wasted afternoon after a midday event. chaining = sensible trip chaining and facility use. coherence = chronological, realistic, not overcrammed.
        """
        return s
    }
}
