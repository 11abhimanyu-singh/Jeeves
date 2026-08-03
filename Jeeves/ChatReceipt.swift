//
//  ChatReceipt.swift
//  Jeeves
//
//  The structured half of a receipt, read back out of the TOOL RESULT — never
//  out of the model's prose.
//
//  The rubric has always demanded that a receipt quote the old value and the
//  new one, and the dual-judge panel failed three scenarios in a row because
//  the reply said "now runs until midnight" while the tool result underneath
//  it said "20:00–23:00 → 20:00–24:00". Prose makes the old value easy to
//  drop. A card with a slot for it does not: an empty slot is visibly wrong.
//
//  Parsing the tool result rather than the reply is the whole point. The tool
//  result is the only text in a turn that is guaranteed to be true — it came
//  from the code that did the work. This type therefore refuses to guess: no
//  recognisable old→new pair means no card, and the prose stands alone.
//

import Foundation

struct ChatReceipt: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case updated, created, deleted }

    var id: UUID = UUID()
    /// What changed — "CGH Earth Wayanad", "Dinner with Arvind".
    var label: String = ""
    /// The value before. Nil for a create or a delete, where there isn't one.
    var was: String?
    /// The value after. For a delete, what was removed.
    var now: String = ""
    var kind: Kind = .updated
    /// The thing the model most likes to bury: a clamp, a hotel-policy clash,
    /// a re-measure, a leg it could not touch.
    var caveat: String?

    // MARK: Parsing

    /// The markers the executor uses when something needs saying out loud.
    /// Each is emitted by ChatToolExecutor verbatim, so this list is a
    /// contract with that file, not a guess about phrasing.
    private static let caveatMarkers = [
        "HOTEL POLICY", "NOTE:", "SHORTER BY", "NOT changed",
        "I couldn't re-measure", "Also removed",
    ]

    /// Pull the caveat sentence out of a result, if it carries one. The
    /// EARLIEST marker wins, not the first one in this list — a clamped shift
    /// says "SHORTER BY 30 MIN" and then re-explains itself under "NOTE:", and
    /// the first statement is the one the user needs.
    static func caveat(in result: String) -> String? {
        let earliest = caveatMarkers
            .compactMap { m in result.range(of: m).map { (marker: m, at: $0.lowerBound) } }
            .min { $0.at < $1.at }
        for marker in [earliest?.marker].compactMap({ $0 }) {
            guard let range = result.range(of: marker) else { continue }
            // From the marker to the end of that sentence, trimmed of the
            // instructions aimed at the model rather than the user.
            let tail = String(result[range.lowerBound...])
            let sentence = tail.split(separator: "\n").first.map(String.init) ?? tail
            let cleaned = sentence
                .replacingOccurrences(of: "HOTEL POLICY — repeat this to the user verbatim, do not resolve it silently: ",
                                      with: "")
                .replacingOccurrences(of: "NOTE: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : String(cleaned.prefix(220))
        }
        return nil
    }

    /// Read a receipt out of one tool result. Returns nil when the result has
    /// no legible before/after — a question, a preview, a refusal, an error.
    static func parse(tool: String, result: String) -> ChatReceipt? {
        // A preview has changed nothing yet, and a refusal changed nothing at
        // all. Neither may render as a receipt: a card is a claim that the
        // store moved.
        // Anchored phrases only. "Which " as a substring blocked a perfectly
        // good hotel-policy receipt because its caveat happened to contain
        // "…12:12, which is 1h 48m before check-in".
        let blocked = ["PREVIEW ONLY", "nothing changed", "NOTHING was changed",
                       "nothing deleted", "I won't guess", "No trip matches",
                       "No stay matches", "No trip covers", "No stay covers",
                       "Which hotel", "Which dates", "Which trip", "Which event",
                       "Need the ", "stays match", "trips match"]
        if blocked.contains(where: { result.localizedCaseInsensitiveContains($0) }) { return nil }

        let caveatText = caveat(in: result)

        // A delete is checked FIRST. Its receipt names the journeys that went
        // with the stay — "…: CGH Earth Wayanad → Western Valley Resort" — and
        // that arrow would otherwise be read as a before/after pair, turning a
        // removal into an "updated" card.
        if firstSentence(result).hasPrefix("Deleted"), let gone = parseDeleted(result) {
            return ChatReceipt(label: gone.label, was: nil, now: gone.now,
                               kind: .deleted, caveat: caveatText)
        }
        // Form 1 — "…: A → B" or "'X' is now B (was A)". Both carry both ends.
        if let arrow = parseArrow(result) {
            return ChatReceipt(label: arrow.label, was: arrow.was, now: arrow.now,
                               kind: .updated, caveat: caveatText)
        }
        if let paren = parseWasParenthetical(firstSentence(result)) {
            return ChatReceipt(label: paren.label, was: paren.was, now: paren.now,
                               kind: .updated, caveat: caveatText)
        }
        // Form 2 — a delete, which has a value but no successor.
        if let gone = parseDeleted(result) {
            return ChatReceipt(label: gone.label, was: nil, now: gone.now,
                               kind: .deleted, caveat: caveatText)
        }
        // Form 3 — a create. Only for tools that genuinely create, so a
        // chatty result from a read tool can't masquerade as one.
        let creators = ["add_stay", "add_trip", "add_journey", "add_event",
                        "add_todo", "add_reminder"]
        if creators.contains(tool), let made = parseCreated(result) {
            return ChatReceipt(label: made.label, was: nil, now: made.now,
                               kind: .created, caveat: caveatText)
        }
        return nil
    }

    /// Every receipt a turn produced, oldest first, de-duplicated by what they
    /// say — one correction restated twice is one change.
    static func parseAll(_ calls: [(tool: String, result: String)]) -> [ChatReceipt] {
        var seen = Set<String>()
        var out: [ChatReceipt] = []
        for call in calls {
            guard let r = parse(tool: call.tool, result: call.result) else { continue }
            let key = "\(r.label)|\(r.was ?? "")|\(r.now)"
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }

    // MARK: shapes

    /// "Updated 1 event(s) (Mon 3 Aug): 20:00–23:00 → 20:00–24:00."
    /// "CGH Earth Wayanad: 13 Sep – 15 Sep → 13 Sep – 19 Sep."
    /// " Moved Mon 3 Aug → Tue 4 Aug."  (a pure day shift changes no times,
    /// so the arrow arrives in a later clause with no colon before it)
    private static func parseArrow(_ text: String) -> (label: String, was: String, now: String)? {
        // Try each clause in turn. The arrow is not always in the first one:
        // shift_by_days leaves the times untouched, so its only before/after
        // pair sits in the trailing "Moved …" sentence.
        for clause in clauses(text) {
            guard let arrowRange = clause.range(of: "→") else { continue }
            let before = String(clause[clause.startIndex..<arrowRange.lowerBound])
            let after = String(clause[arrowRange.upperBound...])

            // The label ends at the first ": " — a colon FOLLOWED BY A SPACE.
            // Searching for a bare colon backwards landed inside "20:00–23:00"
            // and handed back a `was` of "00".
            var label = "", was = ""
            if let colon = before.range(of: ": ") {
                label = tidy(String(before[before.startIndex..<colon.lowerBound]))
                was = tidy(String(before[colon.upperBound...]))
            } else {
                was = tidy(before)
            }
            // Strip the verb that introduces the pair — it duplicates the
            // card's own heading.
            for lead in ["Moved ", "Updated ", "Extended ", "Now "] where was.hasPrefix(lead) {
                was = String(was.dropFirst(lead.count)); break
            }
            let now = tidy(after)
            guard !was.isEmpty, !now.isEmpty else { continue }
            return (cleanLabel(label), was, now)
        }
        return nil
    }

    /// "Updated 1 event(s) (Mon 3 Aug)" is the tool talking to itself. The
    /// card already says UPDATED; what the user needs is the day.
    private static func cleanLabel(_ raw: String) -> String {
        var label = tidy(raw)
        // The LAST parenthetical — "Updated 1 event(s) (Mon 3 Aug)" contains
        // an earlier one in "event(s)", and searching forwards found that.
        if label.hasPrefix("Updated"), let open = label.range(of: "(", options: .backwards),
           let close = label.range(of: ")", options: .backwards),
           open.upperBound < close.lowerBound {
            label = tidy(String(label[open.upperBound..<close.lowerBound]))
        }
        for lead in ["Deleted the ", "Deleted ", "Stay added to "] where label.hasPrefix(lead) {
            label = String(label.dropFirst(lead.count)); break
        }
        label = label.replacingOccurrences(of: "'", with: "")
        return label.isEmpty ? "Updated" : label
    }

    /// Sentences AND semicolon-joined clauses. The executor builds its change
    /// list with "; ", so a clamped shift arrives as
    /// "…: 20:00–24:00 → 20:30–24:00; SHORTER BY 30 MIN — …" and the new value
    /// would otherwise swallow the warning text.
    private static func clauses(_ text: String) -> [String] {
        text.replacingOccurrences(of: ". ", with: "\u{1}")
            .replacingOccurrences(of: "; ", with: "\u{1}")
            .split(separator: "\u{1}")
            .map { tidy(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// "'Mysore' is now 11 Sep–14 Sep (was 11 Sep–13 Sep)."
    private static func parseWasParenthetical(_ text: String) -> (label: String, was: String, now: String)? {
        let head = firstSentence(text)
        guard let isNow = head.range(of: " is now "),
              let wasOpen = head.range(of: "(was ", range: isNow.upperBound..<head.endIndex),
              let close = head.range(of: ")", range: wasOpen.upperBound..<head.endIndex)
        else { return nil }
        let label = tidy(String(head[head.startIndex..<isNow.lowerBound]))
        let now = tidy(String(head[isNow.upperBound..<wasOpen.lowerBound]))
        let was = tidy(String(head[wasOpen.upperBound..<close.lowerBound]))
        guard !was.isEmpty, !now.isEmpty else { return nil }
        return (cleanLabel(label), was, now)
    }

    /// "Deleted the Western Valley Resort stay (10 Aug – 12 Aug)."
    /// "Deleted 'Mysore' (18 Sep–26 Sep) — 3 journey(s) …"
    private static func parseDeleted(_ text: String) -> (label: String, now: String)? {
        let head = firstSentence(text)
        guard head.hasPrefix("Deleted") else { return nil }
        guard let open = head.range(of: "("), let close = head.range(of: ")", range: open.upperBound..<head.endIndex)
        else { return nil }
        var label = tidy(String(head[head.startIndex..<open.lowerBound]))
        for prefix in ["Deleted the ", "Deleted "] where label.hasPrefix(prefix) {
            label = String(label.dropFirst(prefix.count)); break
        }
        let range = tidy(String(head[open.upperBound..<close.lowerBound]))
        guard !label.isEmpty else { return nil }
        return (tidy(label), range)
    }

    /// "Stay added to 'Mysore': CGH Earth Wayanad, 7 Aug – 10 Aug."
    /// "Added \"Appointment with Dr Rao\" 16:00–19:00 on tomorrow at Tasvaa."
    /// "Added todo 'Call the bank' (high), due Mon 4 Aug."
    private static func parseCreated(_ text: String) -> (label: String, now: String)? {
        let head = firstSentence(text)
        // add_event and add_todo quote the thing they made and then run
        // straight on — no colon separates label from value. Their times are
        // full of bare colons, and splitting on the first one put "00–19:00"
        // on a real appointment the user had just booked. The quoted title IS
        // the label; everything after the closing quote is the value.
        if head.hasPrefix("Added "), let quoted = quotedTitle(in: head) {
            let value = tidy(String(head[quoted.after...]))
            if !value.isEmpty { return (tidy(quoted.title), value) }
        }
        // Everything else names itself, then the value, after a colon
        // FOLLOWED BY A SPACE — the same rule parseArrow uses, and for the
        // same reason.
        guard let colon = head.range(of: ": ") else { return nil }
        let label = tidy(String(head[head.startIndex..<colon.lowerBound]))
        let value = tidy(String(head[colon.upperBound...]))
        guard !label.isEmpty, !value.isEmpty else { return nil }
        return (label, value)
    }

    /// The quoted title in a creation receipt, and where it ends. add_event
    /// quotes with `"`, add_todo with `'`. The CLOSING quote is searched
    /// backwards: a receipt carries exactly one quoted title, and searching
    /// forwards cut "Dad's birthday" down to "Dad".
    private static func quotedTitle(in head: String) -> (title: String, after: String.Index)? {
        for quote in ["\"", "'"] {
            guard let open = head.range(of: quote),
                  let close = head.range(of: quote, options: .backwards),
                  open.upperBound <= close.lowerBound
            else { continue }
            let title = tidy(String(head[open.upperBound..<close.lowerBound]))
            guard !title.isEmpty else { continue }
            return (title, close.upperBound)
        }
        return nil
    }

    private static func firstSentence(_ text: String) -> String {
        // Sentences end at ". " — but "7 Aug." and "20:00–24:00." end the line,
        // so the terminal full stop is stripped separately by `tidy`.
        if let stop = text.range(of: ". ") {
            return String(text[text.startIndex..<stop.lowerBound])
        }
        return text
    }

    private static func tidy(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(".") || out.hasSuffix(",") { out = String(out.dropLast()) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: storage

    static func encode(_ receipts: [ChatReceipt]) -> String? {
        guard !receipts.isEmpty, let data = try? JSONEncoder().encode(receipts) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> [ChatReceipt] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ChatReceipt].self, from: data)) ?? []
    }
}

/// What to show the user while a tool runs. A bare spinner reading "Jeeves is
/// thinking…" through four tool calls and eight seconds reads as a hang, and
/// it hides the read path — the exact capability whose absence once had chat
/// answering "no journey is planned" on a morning one existed.
enum ToolActivity {
    static func label(for tool: String, input: [String: Any] = [:]) -> String {
        let collection = (input["collection"] as? String) ?? ""
        switch tool {
        case "fetch_app_data":
            switch collection {
            case "journeys": return "Reading your journeys…"
            case "trips":    return "Reading your trips…"
            case "stays":    return "Reading your hotels…"
            case "events":   return "Reading your calendar…"
            case "lifts", "workouts", "runs": return "Reading your training…"
            case "books":    return "Reading your library…"
            default:         return "Reading your data…"
            }
        case "plan_day", "replan_today":     return "Planning your day…"
        case "set_day_activities":           return "Re-planning around what you kept…"
        case "show_activity_picker":         return "Fetching your activities…"
        case "add_event", "edit_event":      return "Updating your calendar…"
        case "delete_event":                 return "Removing that event…"
        case "add_trip", "update_trip":      return "Updating the trip…"
        case "delete_trip":                  return "Removing the trip…"
        case "add_stay", "update_stay":      return "Updating the hotel…"
        case "delete_stay":                  return "Removing the hotel…"
        case "add_journey", "update_journey": return "Working out when to leave…"
        case "delete_journey":               return "Removing that leg…"
        case "set_gym":                      return "Setting your gym…"
        case "add_todo", "add_reminder":     return "Saving that…"
        case "clean_travel_data":            return "Tidying your travel…"
        default:                             return "Working…"
        }
    }
}
