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

/// Standing preferences the user asked Jeeves to remember ("gym is always
/// 7pm"). Stored in UserDefaults, injected into every agentic turn's state
/// note, editable through the remember_preference tool.
enum StandingPrefs {
    static let key = "jeevesStandingPrefs"

    /// Active (non-lapsed) preferences — what gets injected into the prompt.
    static func all(now: Date = Date()) -> [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { isActive($0, now: now) }
    }

    /// Time-bounded notes carry "(until YYYY-MM-DD)"; they lapse after that
    /// day. Pure and unit-tested.
    nonisolated static func isActive(_ note: String, now: Date) -> Bool {
        guard let range = note.range(of: #"\(until (\d{4}-\d{2}-\d{2})\)"#,
                                     options: .regularExpression) else { return true }
        let dateStr = String(note[range]).dropFirst("(until ".count).dropLast()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let expiry = f.date(from: String(dateStr)) else { return true }
        // Active through the whole expiry day.
        return Calendar.current.startOfDay(for: now) <= Calendar.current.startOfDay(for: expiry)
    }

    /// Stores a preference, REPLACING any existing one that says the same thing
    /// (so re-stating it with a new expiry updates rather than silently
    /// no-ops). Lapsed entries never block a re-add.
    static func add(_ note: String, expires: String? = nil, now: Date = Date()) {
        var trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let expires, !expires.isEmpty, !trimmed.contains("(until") {
            trimmed += " (until \(expires))"
        }
        // Compare on the wording alone, ignoring any "(until …)" suffix.
        let body = stripExpiry(trimmed)
        var prefs = (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { isActive($0, now: now) && stripExpiry($0) != body }
        prefs.append(trimmed)
        UserDefaults.standard.set(prefs, forKey: key)
    }

    /// The preference's wording without its "(until YYYY-MM-DD)" suffix.
    nonisolated static func stripExpiry(_ note: String) -> String {
        note.replacingOccurrences(of: #"\s*\(until [^)]*\)"#, with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    /// Removes stored preferences matching the note (lapsed ones included);
    /// returns how many went.
    @discardableResult
    static func forget(matching note: String) -> Int {
        var prefs = UserDefaults.standard.stringArray(forKey: key) ?? []
        let before = prefs.count
        prefs.removeAll { JeevesChatService.fuzzyMatch($0, query: note) }
        UserDefaults.standard.set(prefs, forKey: key)
        return before - prefs.count
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
    - When the user asks ANY question about their own data — their events, \
    workouts, lifts (PRs, tonnage), runs, the Couch-to-5K programme, to-dos, \
    reminders, check-ins, books — call fetch_app_data with the right collection \
    and answer from what it returns. Do the filtering/counting yourself (e.g. \
    "future events with no venue" = filter the events rows). Never guess or say \
    you can't see the data.
    - When the user asks to remember a task or be reminded of something, use \
    add_todo (untimed task) or add_reminder (timed nudge). One utterance may \
    carry several — add each in the same turn, then confirm all of them briefly.
    - If the user declined an offer this conversation, don't offer it again. \
    When re-checking something (like the calendar) repeatedly, keep repeat \
    reports to one short line — vary the wording, never re-explain.
    - Activity questions span collections: walks live in BOTH workouts and \
    checkins (cardio fields), runs in runs + workouts. Check every relevant \
    collection before saying "nothing logged". When reporting lift tonnage, say \
    whether the number is one session or the whole day.
    - State a limitation UP FRONT the moment it's relevant — never promise a \
    workaround (like re-adding an event) without being sure the tools support it.
    - You can fix events now: edit_event changes venue/time/title, delete_event \
    removes (confirm with the user before deleting). commute_estimate answers \
    "when should I leave" with live traffic. mark_block_done checks off plan \
    blocks ("done with gym"). log_walk records a walk (it auto-ticks the \
    check-in). complete_todo / delete_todo / delete_reminder finish or remove \
    tasks. fetch_chat_history searches older conversations when the user asks \
    about something said before.
    - When the user states a STANDING preference ("gym is always 7pm", "never \
    schedule calls before 10"), call remember_preference — it persists across \
    days and appears in your context. If they time-bound it ("for the next 45 \
    days"), pass the expires date. Honor listed preferences without re-asking.
    - Your CURRENT tool list is the ONLY authority on what you can do. The app \
    gains tools between sessions — if earlier conversation (including your own \
    messages) claimed a capability was missing, that claim is outdated. Check \
    the tool list and use the tool; never repeat a remembered limitation.
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
            "name": "fetch_app_data",
            "description": "Read the user's own app data to answer questions: calendar/planner events, workouts, lift sessions with sets (PRs, tonnage), runs, the Couch-to-5K programme structure, to-dos, reminders, daily check-ins, or the book library. Returns compact JSON rows plus a count. Filter/aggregate the rows yourself to answer.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "collection": [
                        "type": "string",
                        "enum": ["events", "workouts", "lifts", "runs", "run_program",
                                 "todos", "reminders", "checkins", "books"],
                        "description": "Which data to read. 'lifts' includes every set (reps × weight) for PR/tonnage questions; 'run_program' is the Couch-to-5K week structure.",
                    ],
                ],
                "required": ["collection"],
            ],
        ],
        [
            "name": "add_todo",
            "description": "Add an untimed task to the user's to-do list. Use when they ask to remember/do something with no specific alarm time.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "The task, short and imperative — e.g. 'Buy protein powder'"],
                    "priority": ["type": "string", "enum": ["high", "medium", "low"], "description": "Default medium."],
                    "due_date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD. Omit if no due date."],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "add_reminder",
            "description": "Set a timed reminder that fires a notification. Use when the user wants to be nudged at a specific time.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "What to remind, e.g. 'Call Mom'"],
                    "time": ["type": "string", "description": "24-hour HH:MM the reminder should fire, e.g. '18:00'"],
                    "date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD. Default 'today' (rolls to tomorrow if the time already passed)."],
                    "recurrence": ["type": "string", "enum": ["once", "daily", "weekdays", "weekly"], "description": "Default once."],
                ],
                "required": ["title", "time"],
            ],
        ],
        [
            "name": "edit_event",
            "description": "Edit an existing event — change its venue, times, or title. Matches by (partial) title; all matching future events change together (a multi-day event's days all update). Use this instead of re-adding.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Existing event's name, or a distinctive part of it."],
                    "date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD — limit the edit to that day. Omit to edit every future match."],
                    "new_venue": ["type": "string", "description": "New place/address."],
                    "new_start": ["type": "string", "description": "New 24-hour HH:MM start."],
                    "new_end": ["type": "string", "description": "New 24-hour HH:MM end."],
                    "new_title": ["type": "string", "description": "Rename the event."],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "delete_event",
            "description": "Delete event(s) matched by (partial) title — every future match, or one day's if date is given. CONFIRM with the user before calling this; it is not undoable.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Event name (or distinctive part) to delete."],
                    "date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD to limit to one day. Omit to delete all future matches."],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "commute_estimate",
            "description": "Live-traffic commute estimate: how long the drive is and when to leave to arrive on time. Use for 'when should I leave for X'.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "destination": ["type": "string", "description": "Place name or address."],
                    "arrive_by": ["type": "string", "description": "24-hour HH:MM target arrival."],
                    "date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD. Default 'today'."],
                    "origin": ["type": "string", "description": "'Home', 'Work', 'Gym', or an address. Default Home."],
                ],
                "required": ["destination", "arrive_by"],
            ],
        ],
        [
            "name": "log_walk",
            "description": "Record a completed walk (it lands on the Fitness Today feed and auto-ticks the day's check-in cardio). Use when the user says they walked.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "minutes": ["type": "integer", "description": "Walk duration in minutes."],
                    "incline_percent": ["type": "number", "description": "Treadmill incline %, if mentioned."],
                    "date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD. Default 'today'."],
                ],
                "required": ["minutes"],
            ],
        ],
        [
            "name": "mark_block_done",
            "description": "Check off a block in today's plan as done or skipped ('done with gym', 'skipped reading'). Feeds the adherence score.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "block": ["type": "string", "description": "The block's name or a distinctive part ('gym', 'reading', 'lunch')."],
                    "outcome": ["type": "string", "enum": ["done", "skipped"], "description": "Default done."],
                ],
                "required": ["block"],
            ],
        ],
        [
            "name": "complete_todo",
            "description": "Mark an open to-do as done, matched by (partial) title.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "The to-do's title, or a distinctive part."],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "delete_todo",
            "description": "Delete a to-do entirely (open or done), matched by (partial) title.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "The to-do's title, or a distinctive part."],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "delete_reminder",
            "description": "Delete a reminder (its pending notification is cancelled too), matched by (partial) title.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "The reminder's title, or a distinctive part."],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "fetch_chat_history",
            "description": "Search older conversations (beyond the current session). Use when the user references something said before or asks to see older chats.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "days_back": ["type": "integer", "description": "How many days of history to read. Default 7."],
                    "query": ["type": "string", "description": "Filter turns containing this text. Omit for everything in range."],
                ],
            ],
        ],
        [
            "name": "remember_preference",
            "description": "Persist a standing preference ('gym is always at 7pm', 'no calls before 10am') so it survives across days and sessions. Set forget=true to remove a stored preference that matches the note.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "note": ["type": "string", "description": "The preference, short and self-contained."],
                    "expires": ["type": "string", "description": "YYYY-MM-DD after which the preference lapses ('for the next 45 days' → today+45). Omit for permanent."],
                    "forget": ["type": "boolean", "description": "true = remove stored preferences matching this text instead of adding."],
                ],
                "required": ["note"],
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

    /// Resolves add_reminder's date+time arguments into the fire Date. A time
    /// already in the past on the target day rolls forward to the next day (a
    /// "remind me at 9am" typed at 11pm means tomorrow 9am). Pure and testable.
    static func resolveFireDate(dateRaw: String?, timeRaw: String, relativeTo now: Date) -> Date {
        let cal = Calendar.current
        let day = resolveDate(dateRaw, relativeTo: now)
        // Require a real HH:MM — a partially-parsed "9pm" or "23.30" would
        // otherwise schedule the reminder at a silently wrong hour.
        let parts = timeRaw.split(separator: ":").map(String.init)
        let hourValue = parts.count == 2 ? Int(parts[0].trimmingCharacters(in: .whitespaces)) : nil
        let minuteValue = parts.count == 2 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        let hour = hourValue.map { min(23, max(0, $0)) } ?? 9
        let minute = (hourValue == nil ? nil : minuteValue).map { min(59, max(0, $0)) } ?? 0
        var fire = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        if fire <= now {
            fire = cal.date(byAdding: .day, value: 1, to: fire) ?? fire
        }
        return fire
    }

    /// The Couch-to-5K programme, serialized for fetch_app_data("run_program").
    /// Pure over the static programme so it's unit-testable.
    static func runProgramSummary() -> String {
        let weeks = RunProgram.weeks.map { w -> [String: Any] in
            [
                "week": w.number,
                "focus": w.focus,
                "sessionMinutes": w.totalSeconds / 60,
                "runMinutesTotal": w.runSeconds / 60,
                "longestUnbrokenRunMinutes": w.longestRunSeconds / 60,
                "distanceKm": (w.distanceKm * 10).rounded() / 10,
            ]
        }
        let obj: [String: Any] = ["count": weeks.count, "weeks": weeks,
                                  "note": "longestUnbrokenRunMinutes is the continuous-run length that week"]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Case/whitespace-insensitive containment, BOTH directions — a stored
    /// title matches a longer user phrase too ("gym" ← "done with the gym").
    /// Only for read-only/idempotent matching: the reverse direction makes a
    /// specific query match every shorter title inside it, which would delete
    /// "Dinner" while removing "Dinner with Sam". Destructive tools must use
    /// `strictMatch`. Pure and unit-tested.
    nonisolated static func fuzzyMatch(_ text: String, query: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !t.isEmpty else { return false }
        return t.contains(q) || q.contains(t)
    }

    /// One-directional: the stored title must contain the query. What every
    /// edit/delete/complete tool matches on, so a more specific request can
    /// never sweep up shorter-titled records.
    nonisolated static func strictMatch(_ text: String, query: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !t.isEmpty else { return false }
        return t.contains(q)
    }

    /// Narrow a match set the way a human would: if some titles match the
    /// query exactly, those win; otherwise prefer the closest (shortest) title
    /// so "Dinner with Sam" doesn't drag "Dinner" along. Used by the
    /// destructive tools to keep a sloppy query from hitting several records.
    nonisolated static func bestMatches<T>(_ items: [T], title: (T) -> String, query: String) -> [T] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let matches = items.filter { strictMatch(title($0), query: q) }
        guard matches.count > 1 else { return matches }
        let exact = matches.filter { title($0).lowercased().trimmingCharacters(in: .whitespaces) == q }
        if !exact.isEmpty { return exact }
        // Same title on several days (a multi-day event) is a legitimate group;
        // differing titles are not — keep only the closest one.
        let shortest = matches.min { title($0).count < title($1).count }.map { title($0).lowercased() }
        return matches.filter { title($0).lowercased() == shortest }
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
