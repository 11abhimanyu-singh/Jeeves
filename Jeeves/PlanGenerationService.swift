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
            "system": systemPrompt,
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
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw PlanGenerationError.requestFailed(message ?? "Request failed (\(http.statusCode)).")
        }

        struct MessageResponse: Decodable {
            struct ContentBlock: Decodable { let type: String; let text: String? }
            let content: [ContentBlock]
        }
        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text, !text.isEmpty else {
            #if DEBUG
            print("=== RAW PLAN RESPONSE ===\n\(String(data: data, encoding: .utf8) ?? "nil")\n=== END RAW ===")
            #endif
            throw PlanGenerationError.emptyResponse
        }

        // Claude may wrap JSON in prose or a code fence despite instructions;
        // extract the outermost {...} object before decoding.
        let cleaned = extractJSONObject(from: text)
        guard let jsonData = cleaned.data(using: .utf8),
              let plan = try? JSONDecoder().decode(GeneratedPlan.self, from: jsonData) else {
            throw PlanGenerationError.unparsableResponse
        }
        return plan
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

    private static func userPrompt(_ req: PlanRequest) -> String {
        var s = ""

        s += JeevesChatService.dateContext(for: req.referenceNow ?? Date()) + "\n\n"
        s += "TODAY'S REQUEST FROM THE USER:\n\(req.userMessage.isEmpty ? "(no extra context — plan a normal day)" : req.userMessage)\n\n"

        s += "BASELINE ROUTINE (movable blocks, each with a priority tier):\n"
        for a in Baseline.activities {
            s += "- \(a.name): \(a.durationMinutes) min [\(a.tier.rawValue)]"
            if let n = a.note { s += " — \(n)" }
            s += "\n"
        }
        if let neglect = req.prepNeglectNote {
            s += "Practice split guidance: \(neglect). Give the most-neglected the most time (deterministic default 45/35/25/15 by rank).\n"
        }
        s += "\n"

        s += "PRIORITY RULES:\n"
        s += "- Anchors (gym, events) are fixed commitments and sit above all tiers — never move or drop them.\n"
        s += "- Tiers, drop order when things don't fit: Flexible first, then Important. NEVER drop Must-do.\n"
        s += "- Only after dropping should you shrink survivors so the day fits exactly.\n"
        s += "- IMPORTANT-tier floor: never shrink an Important activity below 50% of its allocated time. If fitting the day would force any Important item below 50%, DROP one Important item entirely (vary which one day to day) so the rest run at full length. One activity done fully beats two done at 20 minutes each — you may even extend a surviving Important item into the freed time rather than leaving it idle.\n"
        s += "- Photography is a FLEXIBLE, discretionary-level activity: place it in leftover time or drop it like any Flexible item. It is NOT pinned to the end of the day and has no special end-of-day slot.\n"
        s += "- Which item to drop/shrink first WITHIN a tier is your judgment (context-aware), not a fixed rule.\n"
        s += "- Always report what you dropped and shrank. Never silently omit anything.\n\n"

        s += "DAY WINDOW:\n"
        s += "- The productive window is 08:00 to the 20:30 hard boundary — EVERY day, including event days.\n"
        if !req.events.isEmpty {
            s += "- Events are FIXED ANCHORS you schedule work AROUND, not a wall that ends the day. Each event is an out-and-back trip: leave in time, attend, return home. Fill EVERY free window with productive work — before the first event, between events, and (crucially) AFTER you return home from an event, right up to 20:30.\n"
            s += "- Do NOT drop work just because it doesn't fit before an event. A midday event (e.g. a 2 PM appointment) leaves the whole afternoon and evening free after you return — use it. The ONLY time post-event hours are unavailable is when the event itself runs so late that you get home near or after 20:30.\n"
            s += "- The 08:00 morning peak-focus slot must hold Interview prep — Reading whenever it's free. Never leave the morning empty while dropping a Must-do; with the full 08:00–20:30 window there is almost always room, so dropping a Must-do should essentially never happen.\n"
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
            s += "- Gym: weightlifting starts at \(hhmm(g)). Gym routine is mobility, weightlifting, cardio, shower. Gym routing is always Home → Gym → Home unless chaining to an adjacent event makes Gym → Event sensible.\n"
            let midpoint = (Baseline.dayStartMinute + Baseline.normalBoundaryMinute) / 2   // 14:15
            if g >= midpoint {
                s += "- The gym is in the SECOND half of the day (weightlifting at/after \(hhmm(midpoint))), so ALSO add a short ~15-min morning shower in the morning routine — the user shouldn't go the whole day unshowered — in addition to the usual post-gym shower.\n"
            } else {
                s += "- The gym is in the first half of the day, so the post-gym shower is the only shower needed.\n"
            }
        } else {
            s += "- No gym today.\n"
        }
        for e in req.events {
            s += "- Event: \"\(e.title)\" \(hhmm(e.startMinute))–\(hhmm(e.endMinute)), at \(e.destinationAddress.isEmpty ? "(address not given)" : e.destinationAddress), leaving from \(e.outboundStart.rawValue). Return is always Event → Home.\n"
        }
        s += "\n"

        s += "COMMUTE:\n"
        if req.commuteEstimates.isEmpty {
            s += "- No live traffic data available. Assume \(req.defaultCommuteMinutes) min each way for any trip. Treat these as estimates.\n"
        } else {
            for (route, mins) in req.commuteEstimates.sorted(by: { $0.key < $1.key }) {
                s += "- \(route): \(mins) min\n"
            }
            s += "- For any route not listed, assume \(req.defaultCommuteMinutes) min.\n"
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
            {"title": "Interview prep — Reading", "startTime": "08:00", "endTime": "09:30", "note": "peak focus", "isAnchor": true, "kind": "activity"}
          ],
          "dropped": ["Chores", "Photography"],
          "shrunk": ["Interview prep — practice 120→70"],
          "summary": "Plain-language explanation of the day and every trade-off you made and why.",
          "boundaryTime": "12:30"
        }
        Rules for the JSON:
        - Times are 24-hour "HH:MM". Blocks must be in chronological order and must not overlap.
        - kind is one of: "activity", "commute", "gym", "event", "lunch", "free".
        - Mark gym sub-blocks, events, and the morning peak-focus reading as isAnchor: true.
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
