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
        guard let apiKey = Self.resolveAPIKey() else {
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
        /// The reply asserted a completed action while no tool ran this turn,
        /// and it still did so after being challenged. Surfaced, never hidden.
        var unverifiedClaim: Bool = false
    }

    /// Does this reply assert that something WAS changed? Pure and testable —
    /// the structural half of the no-tool-no-change rule. Deliberately biased
    /// toward false negatives: a missed claim costs a log line, a false alarm
    /// costs the user an extra round trip on a perfectly good answer.
    nonisolated static func claimsCompletedAction(_ text: String) -> Bool {
        // Past-tense completions and present-tense state assertions. Both are
        // claims about stored data ("deleted the stay", "now runs 8–10").
        let claims = [" done", "added", "deleted", "removed", "updated", "extended",
                      "created", "moved", "shifted", "pushed", "cancelled", "canceled",
                      "saved", "swapped", "renamed", "shortened", "lengthened",
                      "now runs", "now ends", "now starts", "is now", "are now",
                      "back to", "all set"]
        // Anything that makes the sentence a question, an offer, a refusal, a
        // future promise — or a NEGATION — is not a claim that something
        // happened. Negations matter most: the challenge below asks the model
        // to retract, and "nothing was updated" is the retraction. Reading that
        // as a fresh claim would punish the exact behaviour we demand.
        let notAClaim = ["want me", "shall i", "should i", "do you want", "would you like",
                         "i'll ", "i will ", "let me know", "if you", "once you",
                         "unable", "not yet", "no change", "still needs", "still ends",
                         "need ", "which ", "what ", "when ", "tell me", "confirm",
                         // generic negations: covers hasn't/wasn't/isn't/aren't/
                         // didn't/couldn't/don't as well as their long forms
                         "n't", " not ", "nothing", "never "]
        for raw in text.lowercased().split(whereSeparator: { ".!?\n;".contains($0) }) {
            let sentence = " " + raw.trimmingCharacters(in: .whitespaces) + " "
            guard claims.contains(where: { sentence.contains($0) }) else { continue }
            if notAClaim.contains(where: { sentence.contains($0) }) { continue }
            return true
        }
        return false
    }

    private static let claimChallenge = """
    SYSTEM CHECK: your reply describes a change ("done", "added", "deleted", \
    "now runs", "that pushes…"), but you called NO tool this turn, so nothing \
    was actually changed. Either call the tool that makes it true now, or \
    rewrite your reply to say plainly what still needs doing. Do not repeat the \
    claim.
    """

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
    - Destructive actions get a RECEIPT, not just "done": after delete_event / \
    delete_todo / delete_reminder, repeat exactly what the tool reported removed \
    (names and days) so the user can spot a wrong deletion immediately.
    - You can fix events now: edit_event changes venue/time/title, delete_event \
    removes (confirm with the user before deleting). commute_estimate answers \
    "when should I leave" with live traffic. mark_block_done checks off plan \
    blocks ("done with gym"). log_walk records a walk (it auto-ticks the \
    check-in). complete_todo / delete_todo / delete_reminder finish or remove \
    tasks. fetch_chat_history searches older conversations when the user asks \
    about something said before.
    - When the user is going away — a trip, a flight, a long drive — call \
    add_trip for the span of days, then add_journey for each flight or drive. \
    Travel mode stops you planning those days; the journeys give the user the \
    one thing that matters: when to leave. For a drive, `time` is when they \
    must ARRIVE; for a flight it's the DEPARTURE. Ask for stops on a long drive \
    (fuel, breakfast) — they push the leave time earlier. Corrections UPDATE \
    the same trip and journey (add_trip reuses an overlapping trip; \
    add_journey updates the same leg) — never re-create from scratch, and use \
    Stays are the itinerary: one add_stay per lodging ("2 nights Radisson \
    Mysore then CGH Earth Wayanad" = two calls, in order) — transitions \
    between them are auto-created as drives. Modify or remove lodgings by \
    hotel name with update_stay/delete_stay; change trip dates with \
    update_trip, never by re-creating the trip. \
    delete_journey to prune a leg the user abandoned. QUOTE leave-by and \
    arrival times ONLY from tool results — never compute times in your head; \
    if you didn't read it in a result, don't say it. When re-planning for \
    lateness, ELAPSED IS NOT DONE: pass the blocks the delay swallowed in \
    missed_blocks and the user's stated ETA in resume_at. Today's date is in \
    your context — never call today "yesterday" or misdate the current \
    session when recapping.
    - When the user states a STANDING preference ("gym is always 7pm", "never \
    schedule calls before 10"), call remember_preference — it persists across \
    days and appears in your context. If they time-bound it ("for the next 45 \
    days"), pass the expires date. Honor listed preferences without re-asking.
    - Your CURRENT tool list is the ONLY authority on what you can do. The app \
    gains tools between sessions — if earlier conversation (including your own \
    messages) claimed a capability was missing, that claim is outdated. Check \
    the tool list and use the tool; never repeat a remembered limitation.
    - BIAS TO ACTION. The rules below exist to stop WRONG actions, not all \
    actions — a build that asks three questions and creates nothing is worse \
    than one that acts and gets corrected. If the user has given you enough to \
    act, ACT, then state your assumptions in the receipt ("assumed 2 nights, \
    arriving the 13th — say the word and I'll change it"). Infer what a person \
    obviously means: "2 days at the Radisson from the 11th" gives you both \
    dates; "next morning" is the day after the leg you just recorded. Ask at \
    most ONE question per turn, and only for something you genuinely cannot \
    infer and cannot safely assume. Never ask the same thing twice.
    - NO TOOL, NO CHANGE: if you did not call a tool THIS turn, nothing \
    changed — never say "done", "removed", "updated", "extended", and never \
    describe anything as auto-added unless a tool result in this conversation \
    says so. Call the tool, or say what you WOULD do and ask. This applies to \
    CONSEQUENCES too: "that pushes your check-in to the 14th" is a claim about \
    stored data — either make that change with a tool or say it still needs \
    doing.
    - NEVER do clock or calendar arithmetic on stored values. "Running an hour \
    long" is extend_by_minutes: 60; "push it 30 minutes" is \
    shift_by_minutes: 30; "postpone it by a day" is shift_by_days: 1 and \
    "prepone it two days" is shift_by_days: -2. DAYS ARE DAYS: one day is \
    shift_by_days 1, never shift_by_minutes 1440 — minutes cannot cross \
    midnight and silently clamp the event to the end of its day. "Postpone" \
    means later and "prepone" means earlier; both are plain requests that need \
    no clarifying question when the event is unambiguous. You do not know an event's stored end time unless a \
    tool result told you — and add_event ASSUMES a 3-hour end when none was \
    given, so guessing has already shortened a dinner it was asked to extend.
    - RECEIPTS ARE VERBATIM: name trips, stays and records EXACTLY as the \
    tool result names them. If a result says the stay went to 'Colombo' and \
    the user meant the Mysore trip, that is the WRONG trip — say so and move \
    it (delete_stay + add_stay with the right trip), never call it the right \
    one.
    - WHAT MAKES IT A NEW TRIP IS GOING HOME, NOT A NEW PLACE. "From Mysore \
    I drive to Wayanad and stay at CGH Earth" is ONE trip continuing — pass \
    the trip they are already on (or leave trip empty) so the window grows; \
    do NOT name a trip after each hotel. Only once a leg has brought them \
    home does the next stay start a NEW trip: pass that trip's name in \
    add_stay's trip field and it is created automatically. A new itinerary \
    that began after a homecoming must never stretch the previous trip.
    - ANSWER FROM THE STORE, NEVER FROM MEMORY. "Any journeys in August?", \
    "how many trips this month", "what's my next flight" — every one of these \
    is fetch_app_data on trips/journeys/stays (with from/to for a month), not \
    a recollection of this conversation and not the events collection. \
    Saying "no journey is planned" without having read journeys is a wrong \
    answer even when it turns out to be true. If a collection comes back \
    empty, say plainly that nothing is stored.
    - International flights: ALWAYS pass from_timezone and to_timezone \
    (IANA IDs) on add_journey — on BOTH legs, return included, even when the \
    offset matches IST.
    - After moving or extending an event on a day that is already planned, \
    OFFER to replan the remainder — don't leave the plan stale, and don't \
    replan silently either.
    """

    // Internal (not private) so ChatToolParityTests can pin this roster
    // against JeevesChatView.handledToolNames.
    static let toolSchemas: [[String: Any]] = [
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
                        "enum": ["events", "trips", "journeys", "stays", "workouts", "lifts",
                                 "runs", "run_program", "todos", "reminders", "checkins", "books"],
                        "description": "Which data to read. ANY question about trips, flights, drives or hotels must read 'trips', 'journeys' or 'stays' — never answer travel from 'events' or from what the conversation said earlier. 'lifts' includes every set (reps × weight) for PR/tonnage questions; 'run_program' is the Couch-to-5K week structure.",
                    ],
                    "from": [
                        "type": "string",
                        "description": "Optional start of a window, yyyy-MM-dd or a phrase like 'next monday'. Applies to trips/journeys/stays. Omit for everything.",
                    ],
                    "to": [
                        "type": "string",
                        "description": "Optional end of the window, inclusive. Use both ends for a question like 'anything in August'.",
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
            "description": "Edit an existing event — change its venue, times, or title. Matches by (partial) title; all matching future events change together (a multi-day event's days all update). Use this instead of re-adding. To make it longer or move it, use extend_by_minutes / shift_by_minutes — the app does the arithmetic from what is STORED, so you never need to know the current times.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Existing event's name, or a distinctive part of it."],
                    "date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD — limit the edit to that day. Omit to edit every future match."],
                    "new_venue": ["type": "string", "description": "New place/address."],
                    "extend_by_minutes": ["type": "integer", "description": "PREFERRED for 'running long' / 'make it an hour longer': lengthen by this many minutes (negative shortens). Computed from the stored end — never work out a new clock time yourself."],
                    "shift_by_minutes": ["type": "integer", "description": "Move the event WITHIN its day, keeping its duration: 'push it 30 minutes' is 30. For whole days use shift_by_days — minutes cannot cross midnight and will clamp."],
                    "shift_by_days": ["type": "integer", "description": "PREFERRED for 'postpone by a day' / 'prepone it two days' / 'push it to next week': move the event to another DATE, keeping its time of day and duration. Negative moves it earlier. One day is 1, never 1440."],
                    "new_start": ["type": "string", "description": "Absolute new 24-hour HH:MM start. Only when the user names an exact time."],
                    "new_end": ["type": "string", "description": "Absolute new 24-hour HH:MM end. Only when the user names an exact time."],
                    "new_title": ["type": "string", "description": "Rename the event."],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "delete_event",
            "description": "Delete event(s) by title, by date, or by date RANGE — 'delete all events from September 1 onwards' is date='2026-09-01' + end_date far out, no title. Title-less range deletes are two-phase: the first call returns the matches WITHOUT deleting; show them to the user, and call again with confirmed=true after they agree. Title-based deletes are immediate — CONFIRM with the user before calling; not undoable.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Event name (or distinctive part). Omit to match every event in the date range."],
                    "date": ["type": "string", "description": "'today', 'tomorrow', or YYYY-MM-DD — a single day, or the range start when end_date is given."],
                    "end_date": ["type": "string", "description": "YYYY-MM-DD inclusive range end. For 'onwards' requests pick a generous end like 2027-12-31."],
                    "confirmed": ["type": "boolean", "description": "Required true to EXECUTE a title-less range delete (after the user saw the preview list)."],
                ],
                "required": [],
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
            "name": "add_trip",
            "description": "Mark a span of days as travel. On those days the planner stands down — no routine, gym or commute — and the user gets journey anchors instead. Create this FIRST, then add each flight or drive with add_journey.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "e.g. 'Bali + Singapore' or 'Bhadra'"],
                    "start_date": ["type": "string", "description": "First travel day, YYYY-MM-DD (or 'today'/'tomorrow')."],
                    "end_date": ["type": "string", "description": "LAST travel day, inclusive, YYYY-MM-DD."],
                ],
                "required": ["title", "start_date", "end_date"],
            ],
        ],
        [
            "name": "add_journey",
            "description": "Add one journey to a trip — a flight (works backwards from its departure through the airline cut-off, security and traffic) or a drive (works backwards from a hard arrival time through the driving and any stops). Returns the leave-by time.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "trip": ["type": "string", "description": "The trip's title (or part of it)."],
                    "mode": ["type": "string", "enum": ["flight", "drive", "train"], "description": "Default flight."],
                    "label": ["type": "string", "description": "Flight number ('6E 1605') or a name ('Drive to Bhadra')."],
                    "from": ["type": "string", "description": "Where the journey starts: 'Home', or a hotel/address when abroad. Default Home."],
                    "to": ["type": "string", "description": "Airport or destination — a real place name so the journey can be measured."],
                    "date": ["type": "string", "description": "YYYY-MM-DD (or 'today'/'tomorrow')."],
                    "time": ["type": "string", "description": "24-hour HH:MM. For a flight this is DEPARTURE on the origin airport's local clock; for a drive it's the time they must ARRIVE, on the DESTINATION's local clock ('reach the lodge by 13:00' is 13:00 where the lodge is)."],
                    "from_timezone": ["type": "string", "description": "IANA zone the departure time is read on, e.g. 'Asia/Kolkata', 'Asia/Singapore'. Omit for journeys that start where the user lives — I'll look it up from the place when I can."],
                    "to_timezone": ["type": "string", "description": "IANA zone at the destination, e.g. 'Asia/Makassar' for Bali."],
                    "arrive_time": ["type": "string", "description": "Flights: scheduled arrival HH:MM on the DESTINATION's clock."],
                    "arrive_date": ["type": "string", "description": "Flights: arrival date YYYY-MM-DD when the flight lands on a different day."],
                    "check_in_minutes": ["type": "integer", "description": "Airline cut-off before departure. Default 180 international, 120 domestic."],
                    "security_minutes": ["type": "integer", "description": "Immigration + security. Default 30."],
                    "stop_minutes": ["type": "integer", "description": "Drives only: total time stopping for fuel, food, rest."],
                    "buffer_minutes": ["type": "integer", "description": "The user's own slack. Default 20."],
                    "travel_minutes": ["type": "integer", "description": "Journey time if known; omit and I'll measure it against live traffic."],
                ],
                "required": ["trip", "to", "date", "time"],
            ],
        ],
        [
            "name": "delete_journey",
            "description": "Delete ONE journey (flight/drive) from a trip and cancel its leave-by notification. Use when the user abandons or replaces a leg. Confirm before calling; report what was deleted.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "trip": ["type": "string", "description": "The trip's title (or part of it)."],
                    "label": ["type": "string", "description": "The journey's name/label (or part), e.g. 'Drive back home'."],
                    "date": ["type": "string", "description": "YYYY-MM-DD the journey belongs to — required when labels are ambiguous."],
                ],
                "required": ["trip", "label"],
            ],
        ],
        [
            "name": "add_stay",
            "description": "Add a lodging to a trip — the itinerary layer ('2 nights at Radisson Mysore, then CGH Earth Wayanad' = two add_stay calls). The trip grows to cover the stay, and a drive transition from the previous lodging is auto-created and measured. One call per hotel.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "trip": ["type": "string", "description": "The trip this stay belongs to. If the stay begins a NEW trip (a new city/region, or after returning home), give the NEW trip's name here — it is created automatically instead of attaching to an old trip."],
                    "hotel": ["type": "string", "description": "Hotel/lodging name, e.g. 'Radisson Blu Mysore'."],
                    "address": ["type": "string", "description": "Address or place detail if the user gave one — helps route measuring."],
                    "arrive_date": ["type": "string", "description": "Check-in day, YYYY-MM-DD (or 'today'/'tomorrow')."],
                    "depart_date": ["type": "string", "description": "Checkout day, YYYY-MM-DD."],
                    "checkin_time": ["type": "string", "description": "When check-in opens, 24-hour HH:MM. Default 14:00. The auto drive from the previous hotel aims at this."],
                    "checkout_time": ["type": "string", "description": "When checkout closes, 24-hour HH:MM. Default 11:30. The onward drive can't leave later than this."],
                ],
                "required": ["trip", "hotel", "arrive_date", "depart_date"],
            ],
        ],
        [
            "name": "update_stay",
            "description": "Change an existing stay — dates, hotel, or address — matched by hotel/place name ('extend the Radisson by a day', 'move the Wayanad stay to Western Valley Resort'). The trip grows if the new dates spill outside it.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "hotel": ["type": "string", "description": "Current hotel/stay name (or part), to find it."],
                    "date": ["type": "string", "description": "A day the stay covers — pins one when several match."],
                    "new_hotel": ["type": "string", "description": "New lodging name, when switching hotels."],
                    "new_address": ["type": "string", "description": "New address."],
                    "new_arrive_date": ["type": "string", "description": "New check-in, YYYY-MM-DD."],
                    "new_depart_date": ["type": "string", "description": "New checkout, YYYY-MM-DD."],
                    "checkin_time": ["type": "string", "description": "When check-in opens, 24-hour HH:MM (default 14:00)."],
                    "checkout_time": ["type": "string", "description": "When checkout closes, 24-hour HH:MM (default 11:30)."],
                ],
                "required": ["hotel"],
            ],
        ],
        [
            "name": "delete_stay",
            "description": "Remove one lodging from a trip, matched by hotel/place name. Two-phase: the first call returns a PREVIEW; call again with confirmed=true after the user agrees. The trip's dates are NOT shrunk automatically — suggest update_trip if the trip is shorter now.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "hotel": ["type": "string", "description": "Hotel/stay name (or part)."],
                    "date": ["type": "string", "description": "A day the stay covers — pins one when several match."],
                    "confirmed": ["type": "boolean", "description": "true only AFTER the user saw the preview and agreed."],
                ],
                "required": ["hotel"],
            ],
        ],
        [
            "name": "update_trip",
            "description": "Change a trip's dates or title — 'add a day to the Mysore trip', 'end it a day early'. Growing sweeps any stored plans on newly covered days; shrinking hands days back to the planner (say so).",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "The trip's title (or part of it)."],
                    "start_date": ["type": "string", "description": "Current start, YYYY-MM-DD — pins one trip when titles collide."],
                    "new_title": ["type": "string", "description": "Rename the trip."],
                    "new_start_date": ["type": "string", "description": "New first day, YYYY-MM-DD."],
                    "new_end_date": ["type": "string", "description": "New last day (inclusive), YYYY-MM-DD."],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "delete_trip",
            "description": "Delete a trip and EVERYTHING under it — its stays, its journeys, and their leave-by notifications. Destructive: confirm with the user before calling, and report exactly what was deleted from the tool result. This is the ONLY way to remove a trip; deleting a trip's calendar events does NOT remove the trip.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "The trip's title (or part of it). Omit with date to match every trip covering that day."],
                    "date": ["type": "string", "description": "YYYY-MM-DD (or 'today') — with NO title, selects every trip covering this day ('delete all trips on Sunday')."],
                    "start_date": ["type": "string", "description": "YYYY-MM-DD start of the trip — pins ONE trip when several share the title."],
                    "all": ["type": "boolean", "description": "true = delete EVERY matching trip (identical clones, or all trips on a date, after the user explicitly confirmed they all go)."],
                ],
                "required": [],
            ],
        ],
        [
            "name": "clean_travel_data",
            "description": "One-time tidy-up of travel data, ONLY when the user explicitly asks to clean/fix/merge their trips: merges trips whose dates genuinely overlap (never back-to-back trips), collapses duplicate stays, and removes rows whose trip no longer exists. Destructive — confirm the user wants it before calling. Reports exactly what changed.",
            "input_schema": [
                "type": "object",
                "properties": [:],
            ],
        ],
        [
            "name": "replan_today",
            "description": "Re-plan ONLY the remainder of TODAY from the current time, keeping everything already done, when reality slipped mid-day (an event ran late, a commute overran, the user is behind schedule). Requires an existing plan for today. Use this instead of plan_day for in-progress disruptions.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "note": ["type": "string", "description": "What happened, in a few words — e.g. 'massage ran 30 min late' or 'running an hour behind'. This drives how the remaining day is re-shaped."],
                    "missed_blocks": ["type": "array", "items": ["type": "string"], "description": "Titles of plan blocks that did NOT happen even though their time passed — e.g. the user was in traffic through 'Gym — Mobility'. ELAPSED IS NOT DONE: when the user was late, name every block the lateness swallowed."],
                    "resume_at": ["type": "string", "description": "24-hour HH:MM the user can actually resume — their stated ETA ('20 more minutes' at 7:05pm = '19:25'). The new plan starts here, not at the current clock."],
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
        guard let apiKey = Self.resolveAPIKey() else {
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
        // The no-tool-no-change rule, enforced structurally instead of hoped
        // for: a prompt rule alone still let "Back to 2 nights — Radisson now
        // ends Aug 13" ship with no tool call behind it.
        var toolsRan = 0
        var challenged = false
        var unverifiedClaim = false

        for _ in 0..<7 {
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 1536,
                // The orchestration layer is lightweight routing (record an
                // event, decide whether to plan) — the real scheduling
                // intelligence lives inside plan_day. Disabling thinking here
                // keeps chat snappy and the tool-use echo simple.
                "thinking": ["type": "disabled"],
                // Split for prompt caching. The cache prefix runs tools →
                // system → messages, so ONE breakpoint on the static system
                // block covers the tool schemas too — ~9.1k tokens (6.8k
                // tools + 2.3k prompt) that used to be re-sent, uncached, on
                // every iteration of the loop below (up to 7 per message).
                //
                // The volatile half MUST stay in a second, unmarked block:
                // dateContext() carries the minute, so folding it into the
                // cached block would change the prefix on every call and the
                // hit rate would be exactly zero. Order is unchanged from the
                // old concatenation, so the model sees the same text.
                "system": [
                    ["type": "text",
                     "text": agenticSystemPrompt,
                     "cache_control": ["type": "ephemeral"]],
                    ["type": "text",
                     "text": dateContext() + "\n\n" + stateNote],
                ],
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

            guard response.stopReason == "tool_use" else {
                // Nothing was called this turn — if the reply nonetheless says
                // something changed, challenge it ONCE and let it either do the
                // work or correct itself.
                if toolsRan == 0, Self.claimsCompletedAction(finalText) {
                    if challenged {
                        unverifiedClaim = true
                    } else {
                        challenged = true
                        messages.append(["role": "user", "content": Self.claimChallenge])
                        continue
                    }
                }
                break
            }

            // Execute each tool call, then send ALL results back in one user turn
            // (splitting them trains the model to stop making parallel calls).
            var toolResults: [[String: Any]] = []
            for block in response.blocks where block.type == "tool_use" {
                let call = ToolCall(id: block.id ?? "", name: block.name ?? "", input: block.input ?? [:])
                let result = await execute(call)
                toolsRan += 1
                if let plan = result.plan { plans.append((plan, result.isOfflinePlan)) }
                toolResults.append([
                    "type": "tool_result",
                    "tool_use_id": call.id,
                    "content": result.text,
                ])
            }
            messages.append(["role": "user", "content": toolResults])
        }

        // Still claiming after the challenge: say so in the reply itself. The
        // user reads the claim, so the correction belongs where they'll see it
        // — the event log alone would surface it a day late, in a digest.
        if unverifiedClaim {
            finalText += "\n\n⚠️ I said that was done, but no change was actually "
                + "recorded — please re-check before relying on it."
        }
        return AgenticReply(text: finalText, plans: plans, unverifiedClaim: unverifiedClaim)
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
    /// Stays matched by hotel/place name or address — "Radisson", "CGH
    /// Earth", "the Mysore hotel" all resolve. Pure, sorted deterministically.
    nonisolated static func staysMatching(_ stays: [TripStay], query: String) -> [TripStay] {
        stays.filter { strictMatch($0.place, query: query) || strictMatch($0.address, query: query) }
            .sorted { ($0.arriveDate, $0.id.uuidString) < ($1.arriveDate, $1.id.uuidString) }
    }

    /// Events whose SPAN touches [start, end] (inclusive, whole days), the
    /// shape behind "delete everything from September 1 onwards". A title
    /// narrows the range; nil matches every event in it. Pure, so the range
    /// arithmetic (multi-day spans included) is pinned by tests.
    nonisolated static func eventsInRange(_ events: [DailyEvent], start: Date, end: Date,
                                          title: String?) -> [DailyEvent] {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: start)
        let hi = cal.startOfDay(for: end)
        return events.filter { e in
            let eStart = cal.startOfDay(for: e.date)
            let eEnd = cal.startOfDay(for: e.spanEndDate ?? e.date)
            guard eEnd >= lo && eStart <= hi else { return false }
            guard let title else { return true }
            return strictMatch(e.title, query: title)
        }
        .sorted { $0.date < $1.date }
    }

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
        /// Cache accounting straight from the API's `usage`. Without this we
        /// would be doing exactly what the iCloud export did for days —
        /// reporting a success we never actually measured.
        var cacheRead: Int = 0
        var cacheWrite: Int = 0
        var uncachedInput: Int = 0
    }

    /// The user's key from Keychain — or, in DEBUG only, from the process
    /// environment, which is how headless trajectory tests run the REAL model
    /// against an in-memory store (the simulator keychain has no key and
    /// never should).
    private static func resolveAPIKey() -> String? {
        if let k = KeychainService.loadAPIKey(), !k.isEmpty { return k }
        #if DEBUG
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        #endif
        return nil
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
        let usage = obj["usage"] as? [String: Any]
        let read = usage?["cache_read_input_tokens"] as? Int ?? 0
        let write = usage?["cache_creation_input_tokens"] as? Int ?? 0
        let plain = usage?["input_tokens"] as? Int ?? 0
        PromptCacheStats.record(read: read, write: write, uncached: plain)
        return Response(stopReason: obj["stop_reason"] as? String ?? "end_turn",
                        rawContent: content, blocks: blocks,
                        cacheRead: read, cacheWrite: write, uncachedInput: plain)
    }
}
