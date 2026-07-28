//
//  JeevesChatService.swift
//  Jeeves
//
//  The Jeeves conversational agent. Two entry points:
//
//  • `send` — plain multi-turn chat (text in, text out). Still used by the
//    live smoke test.
//  • `sendAgentic` — the real assistant: the model is given tools (add an
//    event, set the gym, build the day's plan) and we run the tool-use loop,
//    so a conversation can actually change the day instead of just talking
//    about it. Tool *execution* is delegated to the caller (the view), which
//    owns SwiftData and today's context.
//
//  Raw REST against the Anthropic Messages API — Swift has no official SDK.
//  Key stored in Keychain; the repo is public, so nothing is hardcoded.
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

    /// The model has no clock of its own; give it the device's current date so
    /// it can answer "what's today" and resolve relative dates correctly.
    static func dateContext() -> String { dateContext(for: Date()) }

    /// Overridable "now" — the app passes the real clock; evals pass a fixed
    /// time so plans don't drift with when the test happens to run.
    static func dateContext(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy, h:mm a"
        return "The current date and time on the user's device is \(f.string(from: date))."
    }

    // MARK: - Plain chat (unchanged; used by the live smoke test)

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
            "system": systemPrompt + "\n\n" + Self.dateContext(),
            "messages": messages,
        ]

        let decoded = try await post(body: body, apiKey: apiKey)
        guard let text = decoded.text, !text.isEmpty else { throw JeevesChatError.emptyResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Agentic chat (tool use)

    /// One tool invocation from the model. Execution is delegated to the caller
    /// (the view) because it needs SwiftData + the day's context.
    struct ToolCall {
        let id: String
        let name: String
        let input: [String: Any]
    }

    /// The caller's answer to a tool call: text the model reads next, plus an
    /// optional plan to surface as a timeline card (when the tool was plan_day).
    struct ToolResult {
        let text: String
        var plan: GeneratedPlan? = nil
        var isOfflinePlan: Bool = false
    }

    /// The end of an agentic turn: the final assistant text and any plans that
    /// were generated along the way, in the order they happened.
    struct AgenticReply {
        let text: String
        var plans: [(plan: GeneratedPlan, isOffline: Bool)] = []
    }

    private static let agenticSystemPrompt = """
    You are Jeeves, a personal day-planning assistant inside the user's own iOS \
    productivity app. Unlike a plain chatbot, you can take real actions through \
    tools: record events, set gym plans, and build the full structured schedule \
    for a day.

    How to work:
    - Talk naturally and briefly, in the voice of a sharp, warm assistant.
    - When the user mentions an event or a gym plan, confirm only the specifics \
    you're genuinely unsure about (an ambiguous time, a missing place) in one \
    short question — then record it with add_event / set_gym. Don't ask \
    permission to use a tool; once the details are clear, just do it.
    - When the user asks what's on their calendar, to sync/check it, or to plan \
    around it, call fetch_calendar EVERY time — always do a fresh pull. NEVER \
    answer "it's empty" or "nothing changed since last time" from a previous \
    result or memory; the calendar may have changed, so you must call the tool \
    again and report what it actually returns. All-day events count too (they \
    come back with no time — describe them as "all-day"). Then read the events \
    back and ASK before recording anything ("I see Dentist at 3pm and an all-day \
    'Conference' — want me to plan around these?"). Only after they confirm, call \
    add_event for each one they want. Never silently import calendar events.
    - When the user wants their day planned ("plan my day", "sort out tomorrow"), \
    make sure the events and gym for that day are recorded first, then call \
    plan_day. plan_day does the real scheduling with live commute times and all \
    the lunch/gym/reading rules built in — so NEVER hand-write a timetable \
    yourself; always call the tool.
    - When the day is ALREADY IN PROGRESS and reality slipped — something ran \
    late, a commute took longer, they're behind ("the massage ran 30 min late", \
    "I'm running an hour behind", "redo the rest of my day") — call replan_today \
    with a short note of what happened. It keeps everything already done and \
    re-plans only the remainder from the current time. Use this, NOT plan_day, \
    for mid-day disruptions.
    - After tools run, give a short, warm confirmation of what changed. The app \
    renders the timeline itself, so don't re-list every block.
    - You don't need to reason about commute times, lunch windows, or gym \
    durations — plan_day owns all of that.
    """

    private static let toolSchemas: [[String: Any]] = [
        [
            "name": "add_event",
            "description": "Record a fixed appointment/event on a day (a show, meeting, dinner, flight…). The planner schedules everything else around it. Call this once the event's details are clear.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Short event name, e.g. 'Dinner with Sam' or 'MLR show'"],
                    "start_time": ["type": "string", "description": "24-hour HH:MM, e.g. '19:00'"],
                    "end_time": ["type": "string", "description": "24-hour HH:MM. If the user didn't say, estimate a sensible end from the event type."],
                    "venue": ["type": "string", "description": "Place name or address exactly as the user said it; omit if none."],
                    "leaving_from": ["type": "string", "enum": ["Home", "Work", "Gym"], "description": "Where they head out from. Default Home."],
                    "date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD. Default 'today'."],
                ],
                "required": ["title", "start_time"],
            ],
        ],
        [
            "name": "set_gym",
            "description": "Record whether the user is going to the gym on a day and when weightlifting starts. The gym routine (mobility → weightlifting → cardio) and its commute get scheduled around it.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "gym_today": ["type": "boolean", "description": "true if going to the gym that day; false to clear it."],
                    "gym_time": ["type": "string", "description": "24-hour HH:MM the weightlifting starts. Required when gym_today is true."],
                    "date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD. Default 'today'."],
                ],
                "required": ["gym_today"],
            ],
        ],
        [
            "name": "fetch_calendar",
            "description": "Read the user's Google Calendar events for a day. Use this to answer 'what's on my calendar' or to plan around real appointments. Returns the events as text (it does NOT add them — read them back and confirm with the user first, then call add_event for each one they want).",
            "input_schema": [
                "type": "object",
                "properties": [
                    "date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD. Default 'today'."],
                ],
            ],
        ],
        [
            "name": "plan_day",
            "description": "Build the full structured schedule for a day — with real commute times — around whatever events and gym are set. Call this after the anchors are in place and the user wants the actual plan. Returns a summary; the app renders the timeline card.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD. Default 'today'."],
                    "note": ["type": "string", "description": "Any extra guidance for the planner from the conversation, e.g. 'keep the afternoon light'."],
                ],
            ],
        ],
        [
            "name": "replan_today",
            "description": "Re-plan ONLY the remainder of TODAY from the current time, keeping everything already done, when reality slipped mid-day (an event ran late, a commute overran, the user is behind schedule). Requires an existing plan for today. Use this instead of plan_day for in-progress disruptions.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "note": ["type": "string", "description": "What happened, in a few words — e.g. 'massage ran 30 min late' or 'running an hour behind'. This drives how the remaining day is re-shaped."],
                ],
                "required": ["note"],
            ],
        ],
    ]

    /// Runs a full agentic turn: the model may call tools any number of times
    /// (each executed by `execute`) before producing its final reply. Loops
    /// until the model stops asking for tools, capped so a misbehaving model
    /// can't spin forever.
    static func sendAgentic(
        history: [ChatMessage],
        newMessage: String,
        stateNote: String,
        execute: (ToolCall) async -> ToolResult
    ) async throws -> AgenticReply {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw JeevesChatError.missingAPIKey
        }

        // Prior turns are plain strings; the running turn appends structured
        // content blocks (tool_use / tool_result), which is why `content` is
        // typed loosely here.
        var messages: [[String: Any]] = history.map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        messages.append(["role": "user", "content": newMessage])

        var plans: [(plan: GeneratedPlan, isOffline: Bool)] = []
        var finalText = ""

        for _ in 0..<6 {
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 1536,
                // The orchestration layer is lightweight routing (record an
                // event, decide whether to plan) — the real scheduling
                // intelligence lives inside plan_day. Disabling thinking here
                // keeps chat snappy and the tool-use echo simple.
                "thinking": ["type": "disabled"],
                "system": agenticSystemPrompt + "\n\n" + dateContext() + "\n\n" + stateNote,
                "tools": toolSchemas,
                "messages": messages,
            ]
            let response = try await post(body: body, apiKey: apiKey)

            // Echo the assistant turn back VERBATIM so the tool_use ids line up
            // with the tool_result blocks we send next.
            messages.append(["role": "assistant", "content": response.rawContent])

            let text = response.blocks.compactMap { $0.type == "text" ? $0.text : nil }
                .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { finalText = text }

            guard response.stopReason == "tool_use" else { break }

            // Execute each tool call, then send ALL results back in one user turn
            // (splitting them trains the model to stop making parallel calls).
            var toolResults: [[String: Any]] = []
            for block in response.blocks where block.type == "tool_use" {
                let call = ToolCall(id: block.id ?? "", name: block.name ?? "", input: block.input ?? [:])
                let result = await execute(call)
                if let plan = result.plan { plans.append((plan, result.isOfflinePlan)) }
                toolResults.append([
                    "type": "tool_result",
                    "tool_use_id": call.id,
                    "content": result.text,
                ])
            }
            messages.append(["role": "user", "content": toolResults])
        }

        return AgenticReply(text: finalText, plans: plans)
    }

    // MARK: - Date argument parsing (pure, testable)

    /// Resolves a tool's `date` argument against a reference "today".
    /// Accepts "today", "tomorrow", "day after tomorrow", or "YYYY-MM-DD";
    /// anything unrecognised (or nil) falls back to the reference day. Kept here
    /// so the parsing that governs which day a tool touches is unit-tested.
    static func resolveDate(_ raw: String?, relativeTo today: Date) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: today)
        guard let s = raw?.lowercased().trimmingCharacters(in: .whitespaces), !s.isEmpty else { return base }
        // "day after tomorrow" must be checked before "tomorrow" (it contains it).
        if s.contains("day after tomorrow") { return cal.date(byAdding: .day, value: 2, to: base) ?? base }
        if s.contains("tomorrow") { return cal.date(byAdding: .day, value: 1, to: base) ?? base }
        if s.contains("today") || s.contains("tonight") { return base }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        if let d = f.date(from: s) { return cal.startOfDay(for: d) }
        return base
    }

    // MARK: - Transport

    private struct Response {
        let stopReason: String
        let rawContent: [[String: Any]]   // echo back verbatim on the next turn
        struct Block { let type: String; let text: String?; let id: String?; let name: String?; let input: [String: Any]? }
        let blocks: [Block]
        /// First text block, for the plain-chat path.
        var text: String? { blocks.first { $0.type == "text" }?.text }
    }

    private static func post(body: [String: Any], apiKey: String) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
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
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw JeevesChatError.emptyResponse
        }
        let blocks = content.map { c in
            Response.Block(
                type: c["type"] as? String ?? "",
                text: c["text"] as? String,
                id: c["id"] as? String,
                name: c["name"] as? String,
                input: c["input"] as? [String: Any]
            )
        }
        return Response(stopReason: obj["stop_reason"] as? String ?? "end_turn",
                        rawContent: content, blocks: blocks)
    }
}
