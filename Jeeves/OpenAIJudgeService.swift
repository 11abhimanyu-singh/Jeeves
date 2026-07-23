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
    // Configurable judge model. Note: gpt-5-mini only supports the default
    // temperature, so we omit the temperature param entirely (works across models).
    static let model = "gpt-5-mini"

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
        s += "- Productive window is 08:00–20:30. Interview prep — Reading (90 min) is a HIGH-PREFERENCE Important item (NOT a Must-do, NOT an anchor): strongly prefer it early in the morning, but it may move later or even be dropped when the day is too full — do NOT penalize a sensible move or a justified drop. Lunch (a Must-do) has a window: never before 12:30, ideally finishing by 14:00, with a hard latest start of 14:30 — unless the user is out/travelling over lunch. A lunch before 12:30 is WRONG. Lunch (Must-do) is NEVER dropped.\n"
        s += "- Events (appointments, shows, travel) are fixed anchors you work AROUND. 'Using the full day' means using all AVAILABLE time, not literally 08:00–20:30: if travel or an event blocks part of the day, that time is unavailable and must NOT be counted against the plan. A midday event must not cause the remaining afternoon to be discarded.\n"
        s += "- Drop order when the day is full: Flexible first (Chores, Chore buffer, Photography, discretionary), then Important, never Must-do. Important items shouldn't be shrunk below 50% — dropping one Important item to keep the rest at full length is CORRECT, not a fault. Photography is flexible, not a fixed end-of-day block.\n"
        s += "- Reason like a human: chain adjacent trips (gym→event directly), relocate flexible activities sensibly. The post-gym shower is at HOME after returning — it belongs at the gym ONLY when chaining straight from the gym to an event; do NOT reward an at-gym shower on an ordinary gym→home day.\n"
        s += "- Gym sub-block durations are FIXED: Mobility 20 min, Weightlifting 70 min, Cardio 35 min. A compressed workout (e.g. 45-min weightlifting) is a SERIOUS fault. A late gym legitimately runs past 20:30 — the gym is a fixed commitment like an event, so do NOT penalize gym/commute/shower blocks after 20:30.\n"
        s += "- An activity of 120+ min may be split into TWO parts around an anchor (e.g. practice 90 min, Lunch, then the remaining 30) — that is CORRECT scheduling, never a fault. The gym routine must NEVER be split: mobility → weightlifting → cardio contiguous, nothing in between; a split gym is a SERIOUS fault.\n"
        s += "- WORK ends at the 20:30 boundary. The rest of the evening up to 23:00 is wind-down / personal time and Sleep is a FIXED anchor at 23:00–07:00 — their presence AFTER 20:30 is correct; never penalize it or count it as overrunning the day.\n\n"
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
