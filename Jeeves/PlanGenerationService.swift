//
//  PlanGenerationService.swift
//  Jeeves
//
//  The intelligence at the heart of Jeeves (PRD §5, §6, §7): give Claude the
//  user's baseline routine + tiers, saved locations + facilities, today's
//  anchors (gym + events), real commute times, and the boundary/overflow
//  rules — and have it reason like a human planner (chaining trips, using
//  on-site facilities, relocating flexible activities) to return a single
//  structured schedule. The deterministic DayPlanner remains the offline
//  fallback (PRD §6); this is the primary path.
//
//  The response is parsed by content/type against a strict JSON contract,
//  never by array position (PRD §6), and any malformed/partial response
//  throws so the caller can fall back.
//

import Foundation

struct PlanRequest {
    var userMessage: String            // natural-language context from the chat
    var hasGymToday: Bool
    var gymMinute: Int?                // weightlifting start, minutes since midnight
    var events: [DailyEvent]
    var locations: [SavedLocation]
    var defaultCommuteMinutes: Int     // fallback when a real Maps time isn't available
    var commuteEstimates: [String: Int] // "From→To" → minutes (real, from Google Maps when available)
    var prepNeglectNote: String?       // e.g. "Fewest sessions this week: Behavioral, then Strategy"
    var adherenceNote: String? = nil   // what the user actually does/skips, so the plan adapts
    var replanFromMinute: Int? = nil   // set on a mid-day re-plan: schedule ONLY from here forward
    var alreadyDoneNote: String? = nil // "Morning shower, Photography, Massage" — done earlier, don't re-add
    var routine: [BaselineActivity]? = nil  // the user's editable routine; nil = the hardcoded default
    /// The gym's parts and their minutes, as configured. Defaults to the
    /// historical fixed session so an old caller still produces the old plan.
    var gymSession: [(name: String, minutes: Int)] = Baseline.gymParts
    var referenceNow: Date? = nil      // pinned "now" for evals; nil = real device clock
}

enum PlanGenerationError: LocalizedError {
    case missingAPIKey
    case requestFailed(String)
    case emptyResponse
    case unparsableResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add your Anthropic API key in Library → Settings first."
        case .requestFailed(let m): return m
        case .emptyResponse: return "Jeeves didn't return a plan."
        case .unparsableResponse: return "Couldn't read Jeeves's plan — falling back to the offline planner."
        }
    }
}

enum PlanGenerationService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-opus-4-8"

    static func generate(_ req: PlanRequest) async throws -> GeneratedPlan {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw PlanGenerationError.missingAPIKey
        }

        let body: [String: Any] = [
            "model": model,
            // Opus 4.8 with adaptive thinking. max_tokens is a generous ceiling,
            // NOT a tight cap: thinking and the JSON plan share this budget, and
            // a tight cap (e.g. 6-8k) let thinking consume it on complex days,
            // starving the plan (empty response → fallback). 16k leaves ample
            // room for both so the plan never truncates. (Opus 4.8 rejects
            // budget_tokens with a 400; adaptive thinking is the supported mode.)
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            // The rules moved out of the user message and into a cached system
            // block. 54% of plan runs start within 5 minutes of the previous
            // one (measured over 95 logged generations), so the default 5-min
            // TTL is the right one: at that hit rate a 1-hour TTL's 2x write
            // premium costs more than it saves versus 1.25x.
            "system": [[
                "type": "text",
                "text": planningRules(hasEvents: !req.events.isEmpty),
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": [["role": "user", "content": userPrompt(req)]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Extended thinking + a full JSON plan can run well past URLSession's
        // 60s default; give it room so a slow-but-successful plan isn't killed
        // mid-flight. The UI shows a "Jeeves is planning…" state meanwhile.
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlanGenerationError.requestFailed("No response from server.")
        }
        guard (200...299).contains(http.statusCode) else {
            // Always carry the status code — a 401 (bad key), 429 (rate
            // limit) and 529 (overloaded) each need a different response,
            // and the diagnostics log is where that difference lives.
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw PlanGenerationError.requestFailed(
                "HTTP \(http.statusCode)" + (message.map { ": \($0)" } ?? ""))
        }

        recordCacheUsage(from: data)

        guard let text = extractText(from: data) else {
            #if DEBUG
            print("=== RAW PLAN RESPONSE ===\n\(String(data: data, encoding: .utf8) ?? "nil")\n=== END RAW ===")
            #endif
            throw PlanGenerationError.emptyResponse
        }
        guard let plan = decodePlan(from: text) else {
            throw PlanGenerationError.unparsableResponse
        }
        return plan
    }

    // MARK: Response parsing (pure, testable — no network, no key)

    /// Feed the API's own cache accounting into the daily tally. Runs before
    /// the text checks on purpose: a plan that comes back unparsable still
    /// tells us whether the prefix cached, and that is exactly the run we'd
    /// want the numbers from.
    static func recordCacheUsage(from data: Data) {
        struct UsageEnvelope: Decodable {
            struct Usage: Decodable {
                let input_tokens: Int?
                let cache_read_input_tokens: Int?
                let cache_creation_input_tokens: Int?
            }
            let usage: Usage?
        }
        guard let decoded = try? JSONDecoder().decode(UsageEnvelope.self, from: data),
              let u = decoded.usage else { return }
        PromptCacheStats.record(read: u.cache_read_input_tokens ?? 0,
                                write: u.cache_creation_input_tokens ?? 0,
                                uncached: u.input_tokens ?? 0)
    }

    /// Pulls the assistant's text out of an Anthropic Messages API response body.
    /// The response shape is `{ "content": [ {"type":"text","text":"..."} ], ... }`;
    /// with adaptive thinking a `{"type":"thinking",...}` block (which carries no
    /// `text`) can precede the text block, and a tool_use-only reply or an empty
    /// `content` array has no text block at all. Mirrors GoogleCalendarService.parse:
    /// returns nil on a body it can't decode or one with no usable text block,
    /// rather than throwing — the network caller maps nil to `.emptyResponse`.
    static func extractText(from data: Data) -> String? {
        struct MessageResponse: Decodable {
            struct ContentBlock: Decodable { let type: String; let text: String? }
            let content: [ContentBlock]
        }
        guard let decoded = try? JSONDecoder().decode(MessageResponse.self, from: data) else { return nil }
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text, !text.isEmpty else { return nil }
        return text
    }

    /// Decodes a GeneratedPlan from the assistant's text. Claude may wrap the JSON
    /// in prose or a ```json code fence despite instructions, so the outermost
    /// {...} object is extracted first. Returns nil on unparsable text — the
    /// network caller maps nil to `.unparsableResponse`.
    static func decodePlan(from text: String) -> GeneratedPlan? {
        let cleaned = extractJSONObject(from: text)
        guard let jsonData = cleaned.data(using: .utf8),
              let plan = try? JSONDecoder().decode(GeneratedPlan.self, from: jsonData) else {
            return nil
        }
        return plan
    }

    /// Full pure pipeline: Anthropic response body → GeneratedPlan (or nil). A
    /// convenience over `extractText` + `decodePlan` for tests and callers that
    /// don't need to tell "no text" apart from "unparsable plan".
    static func parse(_ data: Data) -> GeneratedPlan? {
        guard let text = extractText(from: data) else { return nil }
        return decodePlan(from: text)
    }

    private static func extractJSONObject(from text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return s }
        return String(s[start...end])
    }

    // MARK: Prompt

    private static let systemPrompt = """
    You are Jeeves, a personal day-planning assistant. You reason like a thoughtful \
    human planner, not a block-packing algorithm: you chain trips when locations are \
    adjacent, use on-site facilities, and relocate flexible activities to sensible \
    places rather than forcing them into fixed slots. You return ONE structured plan \
    for the user's day as strict JSON and nothing else — no prose outside the JSON.
    """

    /// Internal, not private, so PromptCacheTests can assert the volatile half
    /// stays volatile and the cached half stays byte-stable.
    static func userPrompt(_ req: PlanRequest) -> String {
        var s = ""

        s += JeevesChatService.dateContext(for: req.referenceNow ?? Date()) + "\n\n"
        s += "TODAY'S REQUEST FROM THE USER:\n\(req.userMessage.isEmpty ? "(no extra context — plan a normal day)" : req.userMessage)\n\n"

        if let from = req.replanFromMinute {
            s += "MID-DAY RE-PLAN — the day is ALREADY IN PROGRESS and it is now \(hhmm(from)). "
            s += "Plan ONLY THE REMAINDER of the day, from \(hhmm(from)) to the 20:30 work boundary, then the wind-down block and Sleep. Your FIRST block must begin at approximately \(hhmm(from)); do NOT schedule anything before \(hhmm(from)) (the earlier part of the day already happened and is preserved separately). "
            if let done = req.alreadyDoneNote, !done.isEmpty {
                s += "Already done earlier today — do NOT re-schedule these: \(done). "
            }
            s += "Absorb whatever delay the user described by pushing the remaining activities into the shorter window, dropping/shrinking per the usual tier rules. A Must-do (like lunch) that already happened is in the done list — don't re-add it; one that hasn't AND still fits its window, keep it.\n\n"
        }

        s += "BASELINE ROUTINE (movable blocks, each with a priority tier):\n"
        for a in (req.routine ?? Baseline.activities) {
            s += "- \(a.name): \(a.durationMinutes) min [\(a.tier.rawValue)]"
            if let n = a.note { s += " — \(n)" }
            s += "\n"
        }
        if let neglect = req.prepNeglectNote {
            s += "Practice split guidance: \(neglect). Give the most-neglected the most time (deterministic default 45/35/25/15 by rank).\n"
        }
        if let adherence = req.adherenceNote {
            s += "\(adherence)\n"
        }
        s += "\n"

        s += "SAVED LOCATIONS & FACILITIES:\n"
        if req.locations.isEmpty {
            s += "(none set up yet — assume Home has all at-home activities; Gym has weightlifting, cardio, mobility, shower)\n"
        } else {
            for loc in req.locations {
                s += "- \(loc.kind.rawValue)\(loc.address.isEmpty ? "" : " (\(loc.address))"): \(loc.facilities.joined(separator: ", "))\n"
            }
        }
        s += "\n"

        s += "TODAY'S ANCHORS:\n"
        if req.hasGymToday, let g = req.gymMinute {
            // The parts and their minutes come from the user's routine now —
            // they used to be three numbers written into this sentence and
            // repeated in DayPlanner. The instruction NOT to compress them
            // still stands; only the figures moved.
            let session = req.gymSession
            let anchorName = session.first(where: { $0.name.localizedCaseInsensitiveContains("weight") })?.name
                ?? session.first?.name ?? "Weightlifting"
            let parts = session.map { "\($0.name) \($0.minutes) min" }.joined(separator: ", ")
            s += "- Gym: \(anchorName.lowercased()) starts at \(hhmm(g)). Gym routine is \(session.map(\.name.localizedLowercase).joined(separator: ", ")), with FIXED durations: \(parts). NEVER compress or extend these — the workout is the workout; a late gym runs past 20:30 rather than shrinking (the 20:30 boundary applies to WORK, and the gym is a fixed personal commitment like an event). Title each gym block \"Gym — <part>\". The shower is at HOME after returning from the gym (20 min) — NOT at the gym — unless you're chaining directly from the gym to an event (then shower at the gym to skip the trip home). Gym routing is always Home → Gym → Home unless chaining to an adjacent event makes Gym → Event sensible.\n"
            let midpoint = (Baseline.dayStartMinute + Baseline.normalBoundaryMinute) / 2   // 14:15
            if g >= midpoint {
                s += "- The gym is in the SECOND half of the day (weightlifting at/after \(hhmm(midpoint))), so ALSO add a 20-min morning shower in the morning routine — the user shouldn't go the whole day unshowered. The main shower still happens at home in the evening after the gym (also 20 min).\n"
            } else {
                s += "- The gym is in the first half of the day, so the shower at home after the gym is the only shower needed.\n"
            }
        } else {
            s += "- No gym today.\n"
        }
        for e in req.events where !e.isAllDay {
            s += "- Event: \"\(e.title)\" \(hhmm(e.startMinute))–\(hhmm(e.endMinute)), at \(e.destinationAddress.isEmpty ? "(address not given)" : e.destinationAddress), leaving from \(e.outboundStart.rawValue). Return is always Event → Home.\n"
        }
        for e in req.events where e.isAllDay {
            s += "- All-day: \"\(e.title)\" — occupies the whole day (context only; do NOT create a timed block for it, just plan the day sensibly around it).\n"
        }
        s += "\n"

        s += "COMMUTE:\n"
        // Parking is real time, and it only happens on arrival. The measured
        // minutes and the buffer stay separate in the text so the plan can say
        // "42 min drive + 10 min parking" rather than quoting an inflated 52
        // as though Maps had measured it.
        let park = CommuteBuffer.parkingMinutes
        if req.commuteEstimates.isEmpty {
            s += "- No live traffic data available. Assume \(req.defaultCommuteMinutes) min each way for any trip. Treat these as estimates.\n"
        } else {
            for (route, mins) in req.commuteEstimates.sorted(by: { $0.key < $1.key }) {
                let buffered = CommuteBuffer.needsParking(route: route)
                s += "- \(route): \(mins) min"
                s += buffered ? " + \(park) min parking = \(mins + park) min door to door\n" : "\n"
            }
            s += "- For any route not listed, assume \(req.defaultCommuteMinutes) min.\n"
        }
        s += "- OUTBOUND trips (to the gym, to an event) include \(park) min for parking and walking in — budget the total. Trips ENDING at home do NOT: you park and you're there. Say the two parts separately in the block note.\n"
        s += "\n"

        return s
    }

    /// The half of the prompt that never varies: priorities, the day window,
    /// the chaining doctrine and the response contract. It lives here rather
    /// than inside `userPrompt` so it can be a stable cacheable prefix — the
    /// day's own data (date, request, routine, anchors, commute) changes on
    /// every call, and a single volatile byte ahead of the breakpoint takes
    /// the hit rate to zero.
    ///
    /// `hasEvents` keeps the one conditional rule block conditional. Folding
    /// it in unconditionally would have been simpler and would have given one
    /// cache entry instead of two, but it would also feed event rules into
    /// plans that have no events — a behaviour change smuggled in under a
    /// performance change. Two stable variants, same instructions as before.
    static func planningRules(hasEvents: Bool) -> String {
        var s = systemPrompt + "\n\n"

        s += "PRIORITY RULES:\n"
        s += "- Anchors (gym, events) are fixed commitments and sit above all tiers — never move or drop them.\n"
        s += "- Tiers, drop order when things don't fit: Flexible first, then Important. NEVER drop Must-do.\n"
        s += "- Lunch timing: NEVER before 12:30 (no late-morning brunch). Aim to FINISH lunch by 14:00; the hard latest start is 14:30. So the lunch window is 12:30–14:00 preferred, 14:30 at the very latest.\n"
        s += "- Only after dropping should you shrink survivors so the day fits exactly.\n"
        s += "- IMPORTANT-tier floor: never shrink an Important activity below 50% of its allocated time. If fitting the day would force any Important item below 50%, DROP one Important item entirely (vary which one day to day) so the rest run at full length. One activity done fully beats two done at 20 minutes each — you may even extend a surviving Important item into the freed time rather than leaving it idle.\n"
        s += "- Photography is a FLEXIBLE, discretionary-level activity: place it in leftover time or drop it like any Flexible item. It is NOT pinned to the end of the day and has no special end-of-day slot.\n"
        s += "- SPLITTING: an activity of 120 min or longer may be split into TWO parts around an anchor when it can't fit whole — e.g. Interview prep — practice 90 min, then Lunch, then the remaining 30 min. Label the parts (e.g. \"part 1 of 120\"). Never split shorter activities, and at most one split per activity. The GYM routine must NEVER be split: mobility → weightlifting → cardio run back-to-back as one contiguous sequence with nothing scheduled between them.\n"
        s += "- BREATHER: leave a \(PlanRules.prepBreatherMinutes)-minute gap between any TWO interview-prep blocks that would otherwise run back to back (prep reading and the four practice categories all count). It is a breather and time to switch subject — do not fill it, do not schedule anything in it, and do not remove it to make something else fit. This applies only between prep blocks; every other pair of activities still runs contiguously.\n"
        s += "- Which item to drop/shrink first WITHIN a tier is your judgment (context-aware), not a fixed rule.\n"
        s += "- Always report what you dropped and shrank. Never silently omit anything.\n\n"

        s += "DAY WINDOW:\n"
        s += "- The day STARTS at 07:00 (when sleep ends) — the FIRST block of every plan begins at 07:00. Cover 07:00–08:00 with a morning routine block (kind \"free\", e.g. \"Morning routine — wake, freshen up, breakfast\") unless a real commitment claims that hour. Never leave a gap between 07:00 and the first block.\n"
        s += "- The productive window is \(hhmm(Baseline.dayStartMinute)) to the 20:30 hard boundary — EVERY day, including event days.\n"
        s += "- Sleep is a FIXED 8-hour anchor from 23:00 to 07:00 (11 PM–7 AM) — always the final block of the day (kind \"sleep\", isAnchor true, startTime 23:00, endTime 07:00). No WORK is scheduled after the 20:30 boundary — but the gym routine, events, and their commutes follow their real times and may run later. Fill whatever remains of the evening (from the last block, or 20:30) up to 23:00 with a single wind-down / personal-time block (kind \"free\") leading into sleep.\n"
        if hasEvents {
            s += "- Events are FIXED ANCHORS you schedule work AROUND, not a wall that ends the day. Each event is an out-and-back trip: leave in time, attend, return home. Fill EVERY free window with productive work — before the first event, between events, and (crucially) AFTER you return home from an event, right up to 20:30.\n"
            s += "- Do NOT drop work just because it doesn't fit before an event. A midday event (e.g. a 2 PM appointment) leaves the whole afternoon and evening free after you return — use it. The ONLY time post-event hours are unavailable is when the event itself runs so late that you get home near or after 20:30.\n"
            s += "- STRONGLY PREFER placing Interview prep — Reading early in the morning (the 08:00 peak-focus slot) when it's free — but it is a HIGH-PREFERENCE Important item, NOT an anchor: it may move later, or be dropped like any Important item when the day is genuinely too full. Do not lock it to 08:00.\n"
        }
        s += "\n"

        s += "CHAINING & INTELLIGENCE (reason like a human, not a packer):\n"
        s += "- If two anchors are adjacent in time and place (e.g. gym ends near the event venue), route gym → event directly, skipping gym → home → event.\n"
        s += "- Use on-site facilities: if leaving straight from the gym to an event, take the shower AT the gym.\n"
        s += "- Relocate flexible activities sensibly: e.g. eat near the venue around showtime rather than forcing lunch into a fixed at-home slot. You may infer reasonable options (food near a public venue) without the user listing them.\n"
        s += "- If two fixed anchors physically overlap (can't be at the gym until 13:15 AND leave for a movie at 12:30), DO NOT silently drop one. Flag the clash in the summary and set up the plan around the earlier commitment, noting the user must choose.\n\n"

        s += responseContract()
        return s
    }

    private static func responseContract() -> String {
        """
        RESPOND WITH STRICT JSON ONLY, exactly this shape, no prose outside it:
        {
          "blocks": [
            {"title": "Interview prep — Reading", "startTime": "08:00", "endTime": "09:30", "note": "preferred early slot", "isAnchor": false, "kind": "activity"}
          ],
          "dropped": ["Chores", "Photography"],
          "shrunk": ["Interview prep — practice 120→70"],
          "summary": "Plain-language explanation of the day and every trade-off you made and why.",
          "boundaryTime": "12:30"
        }
        Rules for the JSON:
        - Times are 24-hour "HH:MM". Blocks must be in chronological order and must not overlap.
        - kind is one of: "activity", "commute", "gym", "event", "lunch", "free", "sleep".
        - Mark gym sub-blocks, events, and Sleep as isAnchor: true. Interview prep — Reading is NOT an anchor (isAnchor false).
        - Always end the day with a {"kind":"sleep","title":"Sleep","startTime":"23:00","endTime":"07:00","isAnchor":true} block.
        - boundaryTime is the hard boundary in force (20:30 on a normal day, else the departure time).
        - dropped/shrunk list the human-readable names; leave them as [] if nothing was dropped/shrunk.
        - Fill leftover time before the boundary with a {"kind":"free","title":"Free time",...} block rather than leaving gaps.
        - summary is REQUIRED and must never be empty: 2-4 warm, plain-language sentences, in your voice as Jeeves, explaining the shape of the day, the key chaining/relocation decisions you made and why, and what you dropped or shrank to fit. This is what the user reads first.
        """
    }

    private static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
