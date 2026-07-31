//
//  ChatToolExecutor.swift
//  Jeeves
//
//  Every chat tool, extracted from the view so trajectories can run
//  HEADLESSLY: the same executor the UI uses is driven by XCTest against an
//  in-memory store and the real model, which is what lets the whole Tier 1
//  dialogue plan run without a human typing into the phone. The view owns
//  presentation; this owns state changes. `now` is injectable so tests can
//  pin the clock.
//

import Foundation
import SwiftData
import SwiftUI

@MainActor
final class ChatToolExecutor {
    let modelContext: ModelContext
    var now: () -> Date = { Date() }
    // Headless test runs must not touch UNUserNotificationCenter — a fresh
    // simulator's permission prompt would hang the suite.
    var scheduleNudges = true
    // Injectable for headless test runs — live traffic can't be measured
    // inside an in-memory suite, and travel=0 rows there read as data
    // corruption to every audit. Real runs keep the live lookup.
    var commuteMinutes: (String, String, Date) async -> Int? = { from, to, departure in
        await GoogleMapsService.commuteMinutes(from: from, to: to, departure: departure)
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var today: Date { now().startOfDay }

    // Fresh fetches, never view snapshots — the executor may run with no
    // view alive at all.
    private var locations: [SavedLocation] {
        (try? modelContext.fetch(FetchDescriptor<SavedLocation>())) ?? []
    }
    private var prepSessions: [PrepSession] {
        (try? modelContext.fetch(FetchDescriptor<PrepSession>())) ?? []
    }
    private var routineActivities: [RoutineActivity] {
        (try? modelContext.fetch(FetchDescriptor<RoutineActivity>())) ?? []
    }
    private var todayPlanState: DailyPlanState? {
        let day = today
        return ((try? modelContext.fetch(FetchDescriptor<DailyPlanState>())) ?? [])
            .first { $0.date == day }
    }
    private func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private var allTurns: [ChatTurn] {
        ((try? modelContext.fetch(FetchDescriptor<ChatTurn>())) ?? [])
            .sorted { $0.timestamp < $1.timestamp }
    }

    func run(_ call: JeevesChatService.ToolCall) async -> JeevesChatService.ToolResult {
        let result = await dispatchTool(call)
        let inputDigest = call.input
            .map { "\($0.key)=\(String(describing: $0.value).prefix(40))" }
            .sorted().joined(separator: " ")
        EventLog.log(.toolCall, "\(call.name)(\(inputDigest.prefix(200))) → \(result.text.prefix(300))",
                     context: modelContext)
        return result
    }

    @MainActor
    private func dispatchTool(_ call: JeevesChatService.ToolCall) async -> JeevesChatService.ToolResult {
        switch call.name {
        // NOTE: every case here must appear in handledToolNames below — the
        // parity test pins that list against the schemas the model is shown,
        // so a tool added to one side and not the other fails the suite
        // instead of failing at runtime.
        case "add_event":      return toolAddEvent(call.input)
        case "set_gym":        return toolSetGym(call.input)
        case "fetch_calendar": return await toolFetchCalendar(call.input)
        case "plan_day":       return await toolPlanDay(call.input)
        case "replan_today":   return await toolReplanToday(call.input)
        case "fetch_app_data": return toolFetchAppData(call.input)
        case "add_todo":       return toolAddTodo(call.input)
        case "add_reminder":   return toolAddReminder(call.input)
        case "edit_event":     return toolEditEvent(call.input)
        case "delete_event":   return toolDeleteEvent(call.input)
        case "commute_estimate": return await toolCommuteEstimate(call.input)
        case "log_walk":       return toolLogWalk(call.input)
        case "mark_block_done": return toolMarkBlockDone(call.input)
        case "complete_todo":  return toolCompleteTodo(call.input)
        case "delete_todo":    return toolDeleteTodo(call.input)
        case "delete_reminder": return toolDeleteReminder(call.input)
        case "fetch_chat_history": return toolFetchChatHistory(call.input)
        case "remember_preference": return toolRememberPreference(call.input)
        case "add_trip":       return toolAddTrip(call.input)
        case "add_journey":    return await toolAddJourney(call.input)
        case "clean_travel_data": return toolCleanTravelData()
        case "delete_trip":    return toolDeleteTrip(call.input)
        case "add_stay":       return await toolAddStay(call.input)
        case "update_stay":    return await toolUpdateStay(call.input)
        case "delete_stay":    return toolDeleteStay(call.input)
        case "update_trip":    return await toolUpdateTrip(call.input)
        case "delete_journey": return toolDeleteJourney(call.input)
        default:               return .init(text: "Unknown tool \(call.name).")
        }
    }

    /// Every tool name the switch above dispatches. ChatToolParityTests pins
    /// this against JeevesChatService.toolSchemas, so schema and dispatch
    /// can't drift apart silently — the failure mode where a tool exists on
    /// one side only surfaces as "Unknown tool" at runtime.
    static let handledToolNames: Set<String> = [
        "add_event", "set_gym", "fetch_calendar", "plan_day", "replan_today",
        "fetch_app_data", "add_todo", "add_reminder", "edit_event", "delete_event",
        "commute_estimate", "log_walk", "mark_block_done", "complete_todo",
        "delete_todo", "delete_reminder", "fetch_chat_history", "remember_preference",
        "add_trip", "add_journey", "clean_travel_data", "delete_trip", "delete_journey",
        "add_stay", "update_stay", "delete_stay", "update_trip",
    ]

    /// Removes one journey from a trip, with its nudge and a receipt.
    private func toolDeleteJourney(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let tripQuery = (input["trip"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let labelQuery = (input["label"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        guard let trip = JeevesChatService.bestMatches(trips, title: \.title, query: tripQuery).first else {
            return .init(text: "No trip matches '\(tripQuery)'.")
        }
        var candidates = ((try? modelContext.fetch(FetchDescriptor<TravelSegment>())) ?? [])
            .filter { $0.tripID == trip.id }
            .filter {
                JeevesChatService.strictMatch($0.label.isEmpty ? $0.mode.label : $0.label,
                                              query: labelQuery)
            }
        if candidates.count > 1, let dateRaw = input["date"] as? String {
            let wanted = JeevesChatService.resolveDate(dateRaw, relativeTo: today)
            candidates = candidates.filter { Calendar.current.isDate($0.day, inSameDayAs: wanted) }
        }
        if candidates.count > 1 {
            let list = candidates.map { "\($0.label.isEmpty ? $0.mode.label : $0.label) (\(Self.dayString($0.day)))" }
                .joined(separator: ", ")
            return .init(text: "\(candidates.count) journeys match '\(labelQuery)': \(list). Pass date to pin one.")
        }
        guard let seg = candidates.first else {
            return .init(text: "No journey in '\(trip.title)' matches '\(labelQuery)'.")
        }
        let name = seg.label.isEmpty ? seg.mode.label : seg.label
        let day = Self.dayString(seg.day)
        TravelNotifier.cancel(segment: seg)
        modelContext.delete(seg)
        modelContext.saveOrLog("chat.deleteJourney")
        return .init(text: "Deleted '\(name)' (\(day)) from \(trip.title) — its leave-by nudge is cancelled. The trip and its other journeys are untouched.")
    }

    /// Deletes a trip and everything under it, with a receipt naming exactly
    /// what went. Exists because the coherence eval caught the assistant
    /// CLAIMING a trip deletion it had no tool to perform — the events were
    /// deleted, the trip stayed, and the reply said "Done".
    private func toolDeleteTrip(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let query = (input["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        // "Delete all trips on Sunday" is date-shaped: with no title, a date
        // selects every trip covering that day.
        var candidates: [Trip]
        if query.isEmpty, let dateRaw = input["date"] as? String {
            let day = JeevesChatService.resolveDate(dateRaw, relativeTo: today)
            candidates = trips.filter { $0.covers(day) }
        } else {
            candidates = JeevesChatService.bestMatches(trips, title: \.title, query: query)
        }
        // Two trips can share a title (the clone era minted several "Bali"s).
        // A date narrows it; without one, deleting "the first match" could
        // take the WRONG trip — ask instead.
        if candidates.count > 1, let dateRaw = input["start_date"] as? String {
            let wanted = JeevesChatService.resolveDate(dateRaw, relativeTo: today)
            candidates = candidates.filter { Calendar.current.isDate($0.startDate, inSameDayAs: wanted) }
        }
        // Identical twins (same title, same dates — the clone era minted
        // exactly this) can't be pinned by any field. When the user has
        // confirmed they ALL go, all=true deletes every match with one
        // combined receipt.
        if candidates.count > 1, (input["all"] as? Bool) == true {
            var deletedNames: [String] = []
            var journeyCount = 0
            let allSegs = (try? modelContext.fetch(FetchDescriptor<TravelSegment>())) ?? []
            let allStays = (try? modelContext.fetch(FetchDescriptor<TripStay>())) ?? []
            for trip in candidates {
                for s in allSegs where s.tripID == trip.id {
                    TravelNotifier.cancel(segment: s)
                    modelContext.delete(s)
                    journeyCount += 1
                }
                for st in allStays where st.tripID == trip.id { modelContext.delete(st) }
                deletedNames.append("'\(trip.title.isEmpty ? "Trip" : trip.title)' (\(TravelGuard.dayRange(trip)))")
                modelContext.delete(trip)
            }
            modelContext.saveOrLog("chat.deleteTrip.all")
            EventLog.log(.travelCleanup,
                         "deleted \(deletedNames.count) matching trips, \(journeyCount) journey(s)",
                         context: modelContext)
            return .init(text: "Deleted all \(deletedNames.count) matching trips: \(deletedNames.joined(separator: ", ")) — \(journeyCount) journey(s) went with them, nudges cancelled, planner takes the days back.")
        }
        if candidates.count > 1 {
            let names = candidates.map { "'\($0.title)' (\(TravelGuard.dayRange($0)))" }.joined(separator: ", ")
            return .init(text: "\(candidates.count) trips match '\(query)': \(names). If the user wants ONE, pin it with start_date; if they've confirmed ALL of them go, call again with all=true.")
        }
        guard let trip = candidates.first else {
            let names = trips.map { "'\($0.title)' (\(TravelGuard.dayRange($0)))" }.joined(separator: ", ")
            return .init(text: trips.isEmpty
                         ? "There are no trips to delete."
                         : "No trip matches '\(query)'. Trips: \(names). Ask the user which one.")
        }
        let segments = ((try? modelContext.fetch(FetchDescriptor<TravelSegment>())) ?? [])
            .filter { $0.tripID == trip.id }
        let stays = ((try? modelContext.fetch(FetchDescriptor<TripStay>())) ?? [])
            .filter { $0.tripID == trip.id }
        for s in segments {
            TravelNotifier.cancel(segment: s)
            modelContext.delete(s)
        }
        for st in stays { modelContext.delete(st) }
        let title = trip.title.isEmpty ? "Trip" : trip.title
        let range = TravelGuard.dayRange(trip)
        modelContext.delete(trip)
        modelContext.saveOrLog("chat.deleteTrip")
        EventLog.log(.travelCleanup,
                     "deleted trip '\(title)' with \(segments.count) journey(s), \(stays.count) stay(s)",
                     context: modelContext)
        return .init(text: "Deleted '\(title)' (\(range)) — \(segments.count) journey(s) and \(stays.count) stay(s) went with it, their leave-by nudges are cancelled, and the planner takes those days back.")
    }

    // MARK: Event editing (eval finding: the Bhadra venue struggle)

    /// Events matching a partial title — limited to one day when given, else
    /// today onward (so past history is never edited by accident).
    @MainActor
    private func eventsMatching(_ title: String, dateRaw: String?) -> [DailyEvent] {
        let all = (try? modelContext.fetch(FetchDescriptor<DailyEvent>())) ?? []
        // strict + closest-title: "delete Dinner with Sam" must never also take
        // the separate "Dinner" event.
        let matches = JeevesChatService.bestMatches(all, title: \.title, query: title)
        if let dateRaw, !dateRaw.isEmpty {
            let day = JeevesChatService.resolveDate(dateRaw, relativeTo: Date())
            return matches.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
        }
        return matches.filter { $0.date >= Date().startOfDay }
    }

    private func minutesFrom(_ hhmmRaw: String?) -> Int? {
        guard let parts = hhmmRaw?.split(separator: ":").compactMap({ Int($0) }),
              parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1])
        else { return nil }
        return parts[0] * 60 + parts[1]
    }

    @MainActor
    private func toolEditEvent(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let title = input["title"] as? String ?? ""
        let matches = eventsMatching(title, dateRaw: input["date"] as? String)
        guard !matches.isEmpty else {
            return .init(text: "No future event matches '\(title)'. Use fetch_app_data(events) to see what exists.")
        }
        var changes: [String] = []
        // Parse the times ONCE: a model may send null or a malformed string for
        // new_end, and keying off "was the key present" would then leave the
        // event ending before it starts.
        let newStart = minutesFrom(input["new_start"] as? String)
        let newEnd = minutesFrom(input["new_end"] as? String)
        // Relative deltas: the model must NEVER compute a new clock time from a
        // duration it assumed. "Extend it by an hour" once SHRANK a dinner —
        // the event was stored 20:00–23:00 (a 3 h default), the model believed
        // it ran 20:00–21:00 and set the end to 22:00. Code does this maths.
        let extendBy = input["extend_by_minutes"] as? Int
        let shiftBy = input["shift_by_minutes"] as? Int
        var timesChanged = false
        var clampedNote = ""
        for e in matches {
            let oldStart = e.startMinute, oldEnd = e.endMinute
            if let venue = input["new_venue"] as? String, !venue.isEmpty {
                e.destinationAddress = venue
                // Old coordinates would contradict the new venue.
                e.destinationLat = nil
                e.destinationLng = nil
                changes.append("venue → \(venue)")
            }
            if let start = newStart {
                let duration = max(0, e.endMinute - e.startMinute)
                e.startMinute = start
                // Only the parsed end may override the preserved duration.
                e.endMinute = newEnd ?? min(24 * 60, start + duration)
                // Giving an all-day event real times makes it a timed event.
                if e.isAllDay { e.isAllDay = false; changes.append("now timed") }
            } else if let end = newEnd {
                e.endMinute = max(end, e.startMinute)
                if e.isAllDay { e.isAllDay = false; changes.append("now timed") }
            }
            if let shift = shiftBy, shift != 0 {
                let span = max(0, e.endMinute - e.startMinute)
                e.startMinute = max(0, min(24 * 60, e.startMinute + shift))
                e.endMinute = max(e.startMinute, min(24 * 60, e.startMinute + span))
                if e.isAllDay { e.isAllDay = false; changes.append("now timed") }
            }
            if let extend = extendBy, extend != 0 {
                e.endMinute = max(e.startMinute, min(24 * 60, e.endMinute + extend))
                if e.isAllDay { e.isAllDay = false; changes.append("now timed") }
            }
            // Receipts quote the OLD and the NEW range, never just the new one.
            if e.startMinute != oldStart || e.endMinute != oldEnd {
                timesChanged = true
                changes.append("\(hhmm(oldStart))–\(hhmm(oldEnd)) → \(hhmm(e.startMinute))–\(hhmm(e.endMinute))")
            }
            // The day has edges. If a relative change hit one, say by how much
            // it actually moved — otherwise the reply promises a full hour the
            // event never got.
            if let extend = extendBy, extend != 0 {
                let applied = (e.endMinute - oldEnd)
                if applied != extend {
                    clampedNote = " NOTE: only \(applied) min could be applied (asked for \(extend)) — the day ends at 24:00. Say the real new end, not the requested one."
                }
            }
            if let newTitle = input["new_title"] as? String, !newTitle.isEmpty {
                e.title = newTitle
                changes.append("title → \(newTitle)")
            }
        }
        modelContext.saveOrLog()
        // A pasted Maps link resolves to a real address + pin, same as add_event.
        for e in matches { resolveEventDestinationIfLink(e) }
        let days = matches.map { Self.dayString($0.date) }.joined(separator: ", ")
        // A time change ripples — but only TODAY's plan can go stale mid-day.
        // Gate on whether times ACTUALLY moved, not on which parameter was
        // used: the relative params are the preferred path and were silently
        // skipping this hint, in exactly the two scenarios that test for it.
        let touchesToday = matches.contains { Calendar.current.isDate($0.date, inSameDayAs: today) }
        let replanNote = (timesChanged && touchesToday)
            ? " This changes today — OFFER to replan the remainder (replan_today, with resume_at and any missed_blocks)."
            : ""
        return .init(text: "Updated \(matches.count) event(s) (\(days)): \(Set(changes).joined(separator: "; ")).\(replanNote)\(clampedNote)")
    }

    @MainActor
    private func toolDeleteEvent(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let title = (input["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let dateRaw = input["date"] as? String
        let endRaw = input["end_date"] as? String

        let matches: [DailyEvent]
        if let endRaw {
            // Range mode — how people actually speak ("delete everything from
            // September 1 onwards"). Title narrows it; without one, EVERY
            // event whose span touches the range matches.
            guard let dateRaw else {
                return .init(text: "A range needs a start: pass date with end_date.")
            }
            let start = JeevesChatService.resolveDate(dateRaw, relativeTo: today)
            let end = JeevesChatService.resolveDate(endRaw, relativeTo: today)
            let all = (try? modelContext.fetch(FetchDescriptor<DailyEvent>())) ?? []
            matches = JeevesChatService.eventsInRange(all, start: start, end: end,
                                                     title: title.isEmpty ? nil : title)
            // A title-less range delete is a scythe — two-phase it: preview
            // first, execute only on confirmed=true after the user agreed.
            if title.isEmpty, (input["confirmed"] as? Bool) != true {
                guard !matches.isEmpty else {
                    return .init(text: "No events between \(Self.dayString(start)) and \(Self.dayString(end)) — nothing to delete.")
                }
                let list = matches.map { "\($0.title) (\(Self.dayString($0.date)))" }
                    .joined(separator: ", ")
                return .init(text: "PREVIEW ONLY — nothing deleted yet. \(matches.count) event(s) in range: \(list). Show the user this list; if they confirm, call delete_event again with the same range and confirmed=true.")
            }
        } else {
            guard !title.isEmpty else {
                return .init(text: "Need a title, or a date + end_date range.")
            }
            matches = eventsMatching(title, dateRaw: dateRaw)
        }
        guard !matches.isEmpty else {
            return .init(text: "No future event matches '\(title)' — nothing deleted.")
        }
        let summary = matches.map { "\($0.title) (\(Self.dayString($0.date)))" }.joined(separator: ", ")
        // Deleting a calendar event does NOT delete a trip built from it —
        // the receipt must say so, or the reply claims closure while travel
        // mode quietly survives ("Both are gone from your calendar" while
        // 18–22 Sep stayed in travel mode).
        let deletedDays: [ClosedRange<Date>] = matches.map {
            $0.date.startOfDay...($0.spanEndDate ?? $0.date).startOfDay
        }
        for e in matches {
            // A deleted synced event must STAY deleted — tombstone its
            // calendar ID so the next sync can't resurrect it.
            if !e.externalID.isEmpty {
                modelContext.insert(CalendarTombstone(externalID: e.externalID))
            }
            modelContext.delete(e)
        }
        modelContext.saveOrLog()
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        let surviving = trips.filter { trip in
            deletedDays.contains { range in
                trip.startDate <= range.upperBound && range.lowerBound <= trip.endDate
            }
        }
        var text = "Deleted \(matches.count) event(s): \(summary)."
        if !surviving.isEmpty {
            let names = surviving
                .map { "'\($0.title.isEmpty ? "Trip" : $0.title)' (\(TravelGuard.dayRange($0)))" }
                .joined(separator: ", ")
            text += " NOTE: \(names) still exist(s) — travel mode stays on those days until the trip itself is deleted. Tell the user, and offer delete_trip if they want the trip gone too."
        }
        return .init(text: text)
    }

    // MARK: Commute estimate (eval finding: "when should I leave")

    @MainActor
    private func toolCommuteEstimate(_ input: [String: Any]) async -> JeevesChatService.ToolResult {
        let destination = input["destination"] as? String ?? ""
        guard !destination.isEmpty, let arriveMinute = minutesFrom(input["arrive_by"] as? String) else {
            return .init(text: "Need a destination and an arrive_by time (HH:MM).")
        }
        // Named origins resolve through the user's saved locations.
        let originRaw = (input["origin"] as? String ?? "Home")
        let origin = locations.first { $0.kind.rawValue.lowercased() == originRaw.lowercased() }
            .map(\.address).flatMap { $0.isEmpty ? nil : $0 } ?? originRaw
        let day = JeevesChatService.resolveDate(input["date"] as? String, relativeTo: Date())
        let arrival = Calendar.current.date(bySettingHour: arriveMinute / 60, minute: arriveMinute % 60,
                                            second: 0, of: day) ?? day
        guard let minutes = await commuteMinutes(
            origin, destination, max(arrival.addingTimeInterval(-3600), Date())) else {
            return .init(text: "Couldn't get a route from \(origin) to \(destination) — the Maps key may be missing or the place ambiguous.")
        }
        let buffer = 10
        let leave = arrival.addingTimeInterval(-Double((minutes + buffer) * 60))
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return .init(text: "Drive \(origin) → \(destination): about \(minutes) min with traffic. To arrive by \(hhmm(arriveMinute)) on \(Self.dayString(day)), leave around \(f.string(from: leave)) (includes a \(buffer)-min buffer).")
    }

    // MARK: Fitness capture

    @MainActor
    private func toolLogWalk(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        guard let minutes = input["minutes"] as? Int, minutes > 0 else {
            return .init(text: "Need the walk's minutes.")
        }
        let incline = input["incline_percent"] as? Double ?? 0
        let day = JeevesChatService.resolveDate(input["date"] as? String, relativeTo: Date())
        let date = Calendar.current.isDateInToday(day) ? Date() : day
        let workout = Workout(date: date, type: .walk, state: .done, source: .manual,
                              title: "Walk", durationMin: minutes, inclinePercent: incline)
        modelContext.insert(workout)
        modelContext.saveOrLog()
        return .init(text: "Walk logged: \(minutes) min\(incline > 0 ? " at \(incline)% incline" : "") on \(Self.dayString(day)). The day's check-in cardio ticks itself.")
    }

    @MainActor
    private func toolMarkBlockDone(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let query = input["block"] as? String ?? ""
        let outcome: BlockOutcome = (input["outcome"] as? String) == "skipped" ? .skipped : .done
        guard let state = todayPlanState, let plan = state.plan else {
            return .init(text: "No plan exists for today, so there's no block to check off.")
        }
        let matches = plan.blocks.filter { JeevesChatService.fuzzyMatch($0.title, query: query) }
        guard !matches.isEmpty else {
            let names = plan.blocks.map { $0.title }.joined(separator: ", ")
            return .init(text: "No block matches '\(query)'. Today's blocks: \(names).")
        }
        for block in matches { state.setManualOutcome(outcome, forKey: AdherenceEngine.key(block)) }
        modelContext.saveOrLog()
        return .init(text: "Marked \(outcome == .done ? "done" : "skipped"): \(matches.map { $0.title }.joined(separator: ", ")).")
    }

    // MARK: Task completion / removal

    @MainActor
    private func toolCompleteTodo(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let title = input["title"] as? String ?? ""
        let openTodos = ((try? modelContext.fetch(FetchDescriptor<Todo>())) ?? [])
            .filter { $0.doneAt == nil }
        let open = JeevesChatService.bestMatches(openTodos, title: \.title, query: title)
        guard !open.isEmpty else { return .init(text: "No open to-do matches '\(title)'.") }
        for t in open { t.doneAt = Date() }
        modelContext.saveOrLog()
        return .init(text: "Done: \(open.map(\.title).joined(separator: ", ")).")
    }

    @MainActor
    private func toolDeleteTodo(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let title = input["title"] as? String ?? ""
        let allTodos = (try? modelContext.fetch(FetchDescriptor<Todo>())) ?? []
        let matches = JeevesChatService.bestMatches(allTodos, title: \.title, query: title)
        guard !matches.isEmpty else { return .init(text: "No to-do matches '\(title)'.") }
        let names = matches.map(\.title).joined(separator: ", ")
        for t in matches { modelContext.delete(t) }
        modelContext.saveOrLog()
        return .init(text: "Deleted to-do(s): \(names).")
    }

    @MainActor
    private func toolDeleteReminder(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let title = input["title"] as? String ?? ""
        let all = (try? modelContext.fetch(FetchDescriptor<Reminder>())) ?? []
        let matches = JeevesChatService.bestMatches(all, title: \.title, query: title)
        guard !matches.isEmpty else { return .init(text: "No reminder matches '\(title)'.") }
        let names = matches.map(\.title).joined(separator: ", ")
        for r in matches { modelContext.delete(r) }
        modelContext.saveOrLog()
        ReminderScheduler.reschedule(all.filter { !matches.contains($0) && $0.isActive })
        return .init(text: "Deleted reminder(s): \(names) — their notifications are cancelled.")
    }

    // MARK: Travel mode

    @MainActor
    private func toolAddTrip(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let title = (input["title"] as? String ?? "Trip")
        let start = JeevesChatService.resolveDate(input["start_date"] as? String, relativeTo: today)
        let end = JeevesChatService.resolveDate(input["end_date"] as? String, relativeTo: today)
        guard end >= start else { return .init(text: "The trip's end date is before its start.") }
        // Idempotent, like the UI's accept path: iterating in chat once minted
        // THREE "Shivanasamudra Falls" trips in three minutes because every
        // refinement turn called add_trip again. An overlapping trip is
        // returned, never duplicated.
        let existing = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        if let match = existing.first(where: { !($0.endDate < start || $0.startDate > end) }) {
            return .init(text: "Trip '\(match.title.isEmpty ? "Trip" : match.title)' already covers "
                         + "\(TravelGuard.dayRange(match)) — using it, nothing new created. "
                         + "Add or update journeys with add_journey.")
        }
        let trip = Trip(title: title, startDate: start, endDate: end)
        modelContext.insert(trip)
        modelContext.saveOrLog("chat.addTrip")
        EventLog.log(.tripCreated, "\(title) \(TravelGuard.dayRange(trip)) via chat",
                     subject: trip.id, context: modelContext)
        // The trip now owns these days — stale plans and their notifications go.
        Task { await TravelGuard.sweep(context: modelContext) }
        return .init(text: "Travel mode on for \(trip.dayCount) day(s): \(title), "
                     + "\(Self.dayString(start)) – \(Self.dayString(end)). "
                     + "The planner stands down on those days. Add each flight or drive with add_journey.")
    }

    // MARK: Stays via chat — the itinerary layer ("2 nights at the Radisson,
    // then CGH Earth Wayanad"). Each lodging is a TripStay; consecutive
    // different stays get an auto drive transition, measured in background.

    /// resolveDate silently answers TODAY for anything it can't read — fine
    /// for optional filters, catastrophic for a stay (a garbled date would
    /// mint a trip covering today and sweep today's plan). Only these forms
    /// count as an explicit day.
    private func isExplicitDay(_ raw: String?) -> Bool {
        guard let s = raw?.lowercased().trimmingCharacters(in: .whitespaces), !s.isEmpty else { return false }
        if s.contains("today") || s.contains("tonight") || s.contains("tomorrow") { return true }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s) != nil
    }

    @MainActor
    private func toolAddStay(_ input: [String: Any]) async -> JeevesChatService.ToolResult {
        let place = (input["hotel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !place.isEmpty else { return .init(text: "Need the hotel/place name.") }
        guard isExplicitDay(input["arrive_date"] as? String),
              isExplicitDay(input["depart_date"] as? String) else {
            return .init(text: "Which dates? Give arrive_date and depart_date as YYYY-MM-DD (or 'today'/'tomorrow') — I won't guess.")
        }
        let arrive = JeevesChatService.resolveDate(input["arrive_date"] as? String, relativeTo: today)
        let depart = JeevesChatService.resolveDate(input["depart_date"] as? String, relativeTo: today)
        guard depart >= arrive else { return .init(text: "Checkout is before check-in.") }

        // Trip resolution. The old `?? trips.last` fallback silently attached
        // any unmatched stay to whatever trip happened to exist — a whole
        // Mysore road trip once vanished into the Singapore trip that way.
        // Now: name match wins (with a dead-trip sanity check); an unnamed
        // stay may join a trip FULLY covering its dates; otherwise the stay
        // CREATES its trip — guarded against interior overlap, boundary
        // handover days stay legal.
        let tripQuery = (input["trip"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        var resolved = JeevesChatService.bestMatches(trips, title: \.title, query: tripQuery).first
        if let match = resolved {
            // A name match whose trip ended long before this stay is a NEW
            // trip being described with an old name — don't stretch a fossil.
            let gap = Calendar.current.dateComponents([.day], from: match.endDate,
                                                      to: arrive.startOfDay).day ?? 0
            if gap > 30 {
                return .init(text: "'\(match.title)' ended \(Self.dayString(match.endDate)) — over a month before this stay. If this is a new trip, use a fresh trip name; to really stretch the old one, extend it first with update_trip.")
            }
        }
        if resolved == nil, tripQuery.isEmpty {
            let covering = trips
                .filter { $0.startDate <= arrive.startOfDay && depart.startOfDay <= $0.endDate }
                .sorted { $0.startDate > $1.startDate }
            if covering.count > 1 {
                let names = covering.map { "'\($0.title)' (\(TravelGuard.dayRange($0)))" }
                    .joined(separator: ", ")
                return .init(text: "\(names) all cover those dates — which trip is this stay part of? Name it in trip.")
            }
            resolved = covering.first
        }
        var createdTrip = false
        let trip: Trip
        if let resolved {
            trip = resolved
        } else {
            let newStart = arrive.startOfDay, newEnd = depart.startOfDay
            // STRICT INTERIOR overlap only — trips may legally touch at a
            // handover day (land from Singapore, leave for Mysore). Minting a
            // trip inside another would trip the audit forever and hand
            // clean_travel_data a merge that recreates the merged-Mysore bug.
            if let clash = trips.first(where: { $0.endDate > newStart && $0.startDate < newEnd }) {
                return .init(text: "Those dates sit inside '\(clash.title)' (\(TravelGuard.dayRange(clash))). One set of days belongs to one trip: name '\(clash.title)' in trip to add the stay there, or move its dates first with update_trip.")
            }
            let newTrip = Trip(title: tripQuery.isEmpty ? place : tripQuery,
                               startDate: newStart, endDate: newEnd)
            modelContext.insert(newTrip)
            modelContext.saveOrLog("chat.addStay.newTrip")
            EventLog.log(.tripCreated, "\(newTrip.title) \(TravelGuard.dayRange(newTrip)) via add_stay",
                         subject: newTrip.id, context: modelContext)
            await TravelGuard.sweep(context: modelContext)
            createdTrip = true
            trip = newTrip
        }
        // Idempotent, like add_trip and add_journey: a correction turn ("make
        // that two nights", or the model simply restating the itinerary) must
        // UPDATE the booking, never mint a second one. Same trip + same place +
        // overlapping dates is the same stay. Non-overlapping dates at the same
        // hotel stay separate — a first and last night there are two bookings.
        let siblings = ((try? modelContext.fetch(FetchDescriptor<TripStay>())) ?? [])
            .filter { $0.tripID == trip.id }
        if let existing = siblings.first(where: {
            ($0.place.localizedCaseInsensitiveContains(place)
             || place.localizedCaseInsensitiveContains($0.place))
                && $0.departDate >= arrive.startOfDay && depart.startOfDay >= $0.arriveDate
        }) {
            let oldRange = fmtRange(existing)
            existing.arriveDate = arrive.startOfDay
            existing.departDate = depart.startOfDay
            if let address = input["address"] as? String, !address.isEmpty {
                existing.address = address
            }
            if let m = minutesFrom(input["checkin_time"] as? String) { existing.checkinMinute = m }
            if let m = minutesFrom(input["checkout_time"] as? String) { existing.checkoutMinute = m }
            if arrive.startOfDay < trip.startDate { trip.startDate = arrive.startOfDay }
            if depart.startOfDay > trip.endDate { trip.endDate = depart.startOfDay }
            modelContext.saveOrLog("chat.addStay.upsert")
            EventLog.log(.stayUpdated, "\(existing.place) \(oldRange) → \(fmtRange(existing))",
                         subject: existing.id, context: modelContext)
            return .init(text: "Updated the existing \(existing.place) stay: \(oldRange) → \(fmtRange(existing)). Nothing new created.")
        }

        let stay = TripStay(tripID: trip.id, place: place,
                            address: input["address"] as? String ?? "",
                            arriveDate: arrive, departDate: depart,
                            checkinMinute: minutesFrom(input["checkin_time"] as? String)
                                ?? StayWindow.defaultCheckin,
                            checkoutMinute: minutesFrom(input["checkout_time"] as? String)
                                ?? StayWindow.defaultCheckout)
        modelContext.insert(stay)

        // The trip covers its stays — grow (never shrink) and sweep.
        var grew = false
        if arrive.startOfDay < trip.startDate { trip.startDate = arrive.startOfDay; grew = true }
        if depart.startOfDay > trip.endDate { trip.endDate = depart.startOfDay; grew = true }
        modelContext.saveOrLog("chat.addStay")
        EventLog.log(.stayAdded, "\(place) \(TravelGuard.dayRange(trip)) in '\(trip.title)'",
                     subject: stay.id, context: modelContext)
        if grew { await TravelGuard.sweep(context: modelContext) }

        // Auto drive transition from the previous lodging, like acceptTravel's
        // calendar path — measured in background, nudge scheduled once real.
        var transitionNote = ""
        let stays = ((try? modelContext.fetch(FetchDescriptor<TripStay>())) ?? [])
            .filter { $0.tripID == trip.id && $0.id != stay.id }
        if let prev = stays.filter({ $0.departDate <= arrive.startOfDay && $0.place != place })
            .max(by: { $0.departDate < $1.departDate }) {
            // Aim at the new hotel's CHECK-IN, not a hardcoded noon: noon is
            // after most checkouts and before most check-ins, so it was wrong
            // at both ends of every transition it created.
            let target = Calendar.current.date(bySettingHour: stay.checkinMinute / 60,
                                               minute: stay.checkinMinute % 60,
                                               second: 0, of: arrive) ?? arrive
            let seg = TravelSegment(tripID: trip.id, mode: .drive,
                                    label: "\(prev.place) → \(place)",
                                    fromPlace: prev.address.isEmpty ? prev.place : prev.address,
                                    toPlace: stay.address.isEmpty ? place : stay.address,
                                    arriveBy: target, checkInMinutes: 0, securityMinutes: 0)
            modelContext.insert(seg)
            modelContext.saveOrLog("chat.addStay.transition")
            // Say which of these the user actually told us and which we
            // assumed — quoting a default back as though the hotel stated it
            // is the same class of lie as quoting an unmeasured travel time.
            let statedCheckin = minutesFrom(input["checkin_time"] as? String) != nil
            let checkinPhrase = statedCheckin
                ? "the \(StayWindow.clock(stay.checkinMinute)) check-in"
                : "an ASSUMED \(StayWindow.clock(stay.checkinMinute)) check-in"
            transitionNote = " Added the \(prev.place) → \(place) drive, aiming at \(checkinPhrase)"
                + " (checkout from \(prev.place) taken as \(StayWindow.clock(prev.checkoutMinute)))"
                + " — measuring the route now. Tell the user these are the assumed windows unless"
                + " they gave them, and offer to correct them."
            let checkout = prev.checkoutMinute
            let checkin = stay.checkinMinute
            let day = arrive
            Task {
                if let m = await self.commuteMinutes(seg.fromPlace, seg.toPlace, max(target, Date())) {
                    seg.travelMinutes = m
                    seg.travelIsEstimated = false
                    // Real travel time turns the two hotel policies into an
                    // actual schedule: leave at checkout, and either land after
                    // check-in or wait — the wait is recorded, never hidden.
                    let window = StayWindow.transition(checkoutMinute: checkout,
                                                       checkinMinute: checkin,
                                                       travelMinutes: m)
                    // A long drive can land past midnight; date(bySettingHour:)
                    // returns nil for hour 24+, which silently dropped the
                    // deadline entirely on exactly the journeys that need it.
                    if let deadline = self.at(window.arriveByMinute, on: day) {
                        seg.arriveBy = deadline
                    }
                    modelContext.saveOrLog("chat.addStay.measure")
                    EventLog.log(.journeyMeasured,
                                 "\(seg.label) — \(m) min, leave \(StayWindow.clock(window.leaveMinute))"
                                 + (window.waitMinutes > 0 ? ", waits \(StayWindow.hhmm(window.waitMinutes))" : ""),
                                 subject: seg.id, context: modelContext)
                    await TravelGuard.absorb(seg, context: modelContext)
                    if self.scheduleNudges { await TravelNotifier.schedule(segment: seg) }
                }
            }
        }
        let f = DateFormatter(); f.dateFormat = "d MMM"
        let created = createdTrip
            ? "NEW trip '\(trip.title)' created (\(TravelGuard.dayRange(trip))) for this stay. "
            : ""
        return .init(text: created + "Stay added to '\(trip.title)': \(place), \(f.string(from: arrive)) – \(f.string(from: depart))."
                     + (grew ? " The trip grew to cover it." : "") + transitionNote)
    }

    private func toolUpdateTrip(_ input: [String: Any]) async -> JeevesChatService.ToolResult {
        let query = (input["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        var candidates = JeevesChatService.bestMatches(trips, title: \.title, query: query)
        if candidates.count > 1, let dateRaw = input["start_date"] as? String {
            let wanted = JeevesChatService.resolveDate(dateRaw, relativeTo: today)
            candidates = candidates.filter { Calendar.current.isDate($0.startDate, inSameDayAs: wanted) }
        }
        if candidates.count > 1 {
            let names = candidates.map { "'\($0.title)' (\(TravelGuard.dayRange($0)))" }.joined(separator: ", ")
            return .init(text: "\(candidates.count) trips match: \(names). Pin one with start_date.")
        }
        guard let trip = candidates.first else {
            return .init(text: "No trip matches '\(query)'.")
        }
        let oldRange = TravelGuard.dayRange(trip)
        if let t = input["new_title"] as? String, !t.isEmpty { trip.title = t }
        var grew = false
        if let raw = input["new_start_date"] as? String {
            let d = JeevesChatService.resolveDate(raw, relativeTo: today).startOfDay
            if d < trip.startDate { grew = true }
            trip.startDate = d
        }
        if let raw = input["new_end_date"] as? String {
            let d = JeevesChatService.resolveDate(raw, relativeTo: today).startOfDay
            if d > trip.endDate { grew = true }
            trip.endDate = d
        }
        guard trip.endDate >= trip.startDate else {
            return .init(text: "Those dates end before they start — nothing changed.")
        }
        modelContext.saveOrLog("chat.updateTrip")
        EventLog.log(.tripUpdated, "'\(trip.title)' \(oldRange) → \(TravelGuard.dayRange(trip))",
                     subject: trip.id, context: modelContext)
        if grew { await TravelGuard.sweep(context: modelContext) }
        // Every nudge in this trip is re-armed, not just the ones the changed
        // days happened to touch: a leg whose day fell outside the new window
        // kept a live notification that would fire for travel that no longer
        // exists.
        let renudged = await rescheduleNudges(for: trip)
        let shrinkNote = grew ? "" : " Days no longer covered go back to the planner — it will fill them again."
        return .init(text: "'\(trip.title)' is now \(TravelGuard.dayRange(trip)) (was \(oldRange)).\(shrinkNote)\(renudged)")
    }

    private func toolUpdateStay(_ input: [String: Any]) async -> JeevesChatService.ToolResult {
        let query = (input["hotel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return .init(text: "Which hotel/stay? Give me its name.") }
        let stays = (try? modelContext.fetch(FetchDescriptor<TripStay>())) ?? []
        var matches = JeevesChatService.staysMatching(stays, query: query)
        if matches.count > 1, let dateRaw = input["date"] as? String {
            let wanted = JeevesChatService.resolveDate(dateRaw, relativeTo: today)
            matches = matches.filter { $0.covers(wanted) }
        }
        if matches.count > 1 {
            let f = DateFormatter(); f.dateFormat = "d MMM"
            let names = matches.map { "\($0.place) (\(f.string(from: $0.arriveDate))–\(f.string(from: $0.departDate)))" }
                .joined(separator: ", ")
            return .init(text: "\(matches.count) stays match '\(query)': \(names). Pin one with date.")
        }
        guard let stay = matches.first else {
            return .init(text: "No stay matches '\(query)'.")
        }
        if let h = input["new_hotel"] as? String, !h.isEmpty { stay.place = h }
        if let a = input["new_address"] as? String, !a.isEmpty { stay.address = a }
        // Validate BEFORE writing: the guard used to run after the assignments,
        // so an inverted range was already persisted by the time the reply
        // said "nothing changed" — a false receipt on top of corrupt dates.
        let cal = Calendar.current
        let oldArrive = stay.arriveDate, oldDepart = stay.departDate
        let wantArrive = (input["new_arrive_date"] as? String)
            .map { JeevesChatService.resolveDate($0, relativeTo: today).startOfDay } ?? oldArrive
        let wantDepart = (input["new_depart_date"] as? String)
            .map { JeevesChatService.resolveDate($0, relativeTo: today).startOfDay } ?? oldDepart
        guard wantDepart >= wantArrive else {
            return .init(text: "That checkout (\(Self.dayString(wantDepart))) is before check-in (\(Self.dayString(wantArrive))) — nothing changed.")
        }
        stay.arriveDate = wantArrive
        stay.departDate = wantDepart
        if let m = minutesFrom(input["checkin_time"] as? String) { stay.checkinMinute = m }
        if let m = minutesFrom(input["checkout_time"] as? String) { stay.checkoutMinute = m }
        let dayShift = (
            arriveDelta: cal.dateComponents([.day], from: oldArrive, to: wantArrive).day ?? 0,
            departDelta: cal.dateComponents([.day], from: oldDepart, to: wantDepart).day ?? 0
        )
        // The trip still covers its stays.
        var grew = false
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        if let trip = trips.first(where: { $0.id == stay.tripID }) {
            if stay.arriveDate < trip.startDate { trip.startDate = stay.arriveDate; grew = true }
            if stay.departDate > trip.endDate { trip.endDate = stay.departDate; grew = true }
        }
        modelContext.saveOrLog("chat.updateStay")
        EventLog.log(.stayUpdated, "\(stay.place) now \(fmtRange(stay))", subject: stay.id,
                     context: modelContext)
        if grew { await TravelGuard.sweep(context: modelContext) }
        // Moving a stay moves the drives either side of it. Without this the
        // receipt said the stay changed while its journeys silently kept the
        // old days, times and measured minutes — two records disagreeing about
        // the same trip.
        let touched = await resyncJourneys(around: stay, dayShift: dayShift)
        return .init(text: "\(stay.place): \(fmtRange(stay))."
                     + (grew ? " The trip grew to cover it." : "") + touched)
    }

    private func toolDeleteStay(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let query = (input["hotel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return .init(text: "Which hotel/stay? Give me its name.") }
        let stays = (try? modelContext.fetch(FetchDescriptor<TripStay>())) ?? []
        var matches = JeevesChatService.staysMatching(stays, query: query)
        if matches.count > 1, let dateRaw = input["date"] as? String {
            let wanted = JeevesChatService.resolveDate(dateRaw, relativeTo: today)
            matches = matches.filter { $0.covers(wanted) }
        }
        if matches.count > 1 {
            let f = DateFormatter(); f.dateFormat = "d MMM"
            let names = matches.map { "\($0.place) (\(f.string(from: $0.arriveDate))–\(f.string(from: $0.departDate)))" }
                .joined(separator: ", ")
            return .init(text: "\(matches.count) stays match '\(query)': \(names). Pin one with date.")
        }
        guard let stay = matches.first else {
            return .init(text: "No stay matches '\(query)' — nothing deleted.")
        }
        // Destructive → preview first, execute only on confirmed=true.
        if (input["confirmed"] as? Bool) != true {
            let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
            let tripName = trips.first { $0.id == stay.tripID }?.title ?? "its trip"
            return .init(text: "PREVIEW ONLY — nothing deleted yet. This removes the \(stay.place) stay (\(fmtRange(stay))) from '\(tripName)'. Show the user; if they confirm, call delete_stay again with confirmed=true.")
        }
        let name = stay.place
        let range = fmtRange(stay)
        modelContext.delete(stay)
        modelContext.saveOrLog("chat.deleteStay")
        EventLog.log(.stayDeleted, "\(name) \(range)", context: modelContext)
        return .init(text: "Deleted the \(name) stay (\(range)). The trip's dates are unchanged — shrink them with update_trip if the trip is shorter now, and check its journeys still make sense.")
    }

    /// Cancel and re-arm the leave-by nudge for every journey in a trip whose
    /// window just moved. A leg now outside the trip loses its nudge entirely
    /// rather than firing for travel that isn't happening.
    @MainActor
    private func rescheduleNudges(for trip: Trip) async -> String {
        guard scheduleNudges else { return "" }
        let segments = ((try? modelContext.fetch(FetchDescriptor<TravelSegment>())) ?? [])
            .filter { $0.tripID == trip.id }
        guard !segments.isEmpty else { return "" }
        var live = 0, dropped = 0
        for seg in segments {
            TravelNotifier.cancel(segment: seg)
            let day = Calendar.current.startOfDay(for: seg.day)
            if day >= trip.startDate && day <= trip.endDate {
                await TravelNotifier.schedule(segment: seg)
                live += 1
            } else {
                EventLog.log(.nudgeCancelled,
                             "\(seg.label) on \(Self.dayString(day)) falls outside '\(trip.title)' \(TravelGuard.dayRange(trip))",
                             subject: seg.id, context: modelContext)
                dropped += 1
            }
        }
        var note = " Leave-by reminders re-armed for \(live) journey(s)."
        if dropped > 0 {
            note += " \(dropped) now fall outside the trip — their reminders were cancelled; tell the user."
        }
        return note
    }

    /// Re-anchor, re-measure and re-nudge the drives that touch a stay whose
    /// dates just moved. A drive INTO the stay lands on its new check-in day;
    /// a drive OUT of it leaves on the new checkout day. Returns the receipt
    /// fragment naming what moved — silence here is how the store ends up
    /// disagreeing with itself.
    @MainActor
    private func resyncJourneys(around stay: TripStay,
                                dayShift: (arriveDelta: Int, departDelta: Int)) async -> String {
        guard dayShift.arriveDelta != 0 || dayShift.departDelta != 0 else { return "" }
        let segments = ((try? modelContext.fetch(FetchDescriptor<TravelSegment>())) ?? [])
            .filter { $0.tripID == stay.tripID }

        // One-directional on purpose. Matching BOTH ways meant a segment
        // endpoint of "Mysore" matched the stay "Radisson Mysore" — and so did
        // every other Mysore hotel's legs, so moving one stay dragged another
        // stay's drives with it. The endpoint must name this stay, not merely
        // share a city with it.
        func matches(_ endpoint: String) -> Bool {
            let e = endpoint.trimmingCharacters(in: .whitespaces)
            guard e.count >= 3 else { return false }
            if e.localizedCaseInsensitiveCompare(stay.place) == .orderedSame { return true }
            if e.localizedCaseInsensitiveContains(stay.place), stay.place.count >= 3 { return true }
            if !stay.address.isEmpty, e.localizedCaseInsensitiveContains(stay.address) { return true }
            return false
        }

        var moved: [String] = []
        var measured: [String] = []
        var untouched: [String] = []
        for seg in segments {
            let arriving = matches(seg.toPlace)
            let leaving = matches(seg.fromPlace)
            guard arriving || leaving else { continue }

            // DRIVES ONLY. A flight's departAt is airline data read on the
            // ORIGIN clock, not something to derive from a hotel policy —
            // and JourneyPrefill deliberately sets a return flight's fromPlace
            // to the last stay's address, so every return leg matches here.
            // Re-anchoring one would have replaced a real 21:15 departure with
            // a fabricated 11:30 and handed back a leave-by ten hours early.
            guard seg.mode == .drive else {
                untouched.append(seg.label.isEmpty ? seg.mode.label : seg.label)
                continue
            }

            let newAnchor: Date?
            if arriving {
                // A drive INTO this stay lands at its check-in.
                newAnchor = at(stay.checkinMinute, on: stay.arriveDate)
            } else {
                // A drive OUT of it keeps its own deadline — arriveBy is when
                // you must reach the NEXT place ("home by 6 pm"), which this
                // hotel's checkout has no business overwriting. Only the DAY
                // follows the stay; the time of day is the user's.
                let shift = dayShift.departDelta
                guard shift != 0, let old = seg.arriveBy else { newAnchor = nil
                    if shift != 0 { untouched.append(seg.label.isEmpty ? seg.mode.label : seg.label) }
                    continue
                }
                newAnchor = Calendar.current.date(byAdding: .day, value: shift, to: old)
            }
            guard let anchor = newAnchor else { continue }
            seg.arriveBy = anchor

            // The old measurement was for a different day's traffic. Only
            // claim a re-measure when one actually came back.
            var didMeasure = false
            if !seg.toPlace.isEmpty,
               let m = await commuteMinutes(seg.fromPlace, seg.toPlace, max(anchor, Date())) {
                seg.travelMinutes = m
                seg.travelIsEstimated = false
                didMeasure = true
            }
            modelContext.saveOrLog("chat.updateStay.resync")
            EventLog.log(.journeySaved,
                         "\(seg.label) re-anchored to \(Self.dayString(anchor)) after \(stay.place) moved"
                         + (didMeasure ? ", re-measured" : ", measurement unchanged"),
                         subject: seg.id, context: modelContext)
            await TravelGuard.absorb(seg, context: modelContext)
            if scheduleNudges {
                TravelNotifier.cancel(segment: seg)
                await TravelNotifier.schedule(segment: seg)
            }
            let label = seg.label.isEmpty ? seg.mode.label : seg.label
            moved.append(label)
            if didMeasure { measured.append(label) }
        }

        var note = ""
        if !moved.isEmpty {
            note += " Moved \(moved.count) drive(s) with it: " + moved.joined(separator: ", ") + "."
            note += measured.isEmpty
                ? " I couldn't re-measure them — the times shown are the old ones."
                : " Re-measured: \(measured.joined(separator: ", "))."
        }
        // Surfaced, never silently adjusted: the user has to re-book a flight,
        // so say the dates moved underneath it.
        if !untouched.isEmpty {
            note += " NOT changed — these have booked times only the airline can move, so check them: "
                + untouched.joined(separator: ", ") + "."
        }
        return note
    }

    /// A Date at `minute` past midnight on `day`, carrying past midnight
    /// correctly. date(bySettingHour:) returns nil for hour 24+, which silently
    /// dropped the deadline on any drive long enough to land the next day.
    private func at(_ minute: Int, on day: Date) -> Date? {
        let cal = Calendar.current
        let extraDays = minute / (24 * 60)
        let within = minute % (24 * 60)
        guard let base = cal.date(bySettingHour: within / 60, minute: within % 60,
                                  second: 0, of: day) else { return nil }
        return extraDays == 0 ? base : cal.date(byAdding: .day, value: extraDays, to: base)
    }

    private func fmtRange(_ stay: TripStay) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return "\(f.string(from: stay.arriveDate)) – \(f.string(from: stay.departDate))"
    }

    /// Destructive tidying, only ever reached when the user explicitly asked
    /// for it in chat — never automatic. The receipt lists exactly what
    /// changed, per the deletion-receipts rule.
    private func toolCleanTravelData() -> JeevesChatService.ToolResult {
        let summary = TravelRepair.cleanupLegacy(context: modelContext)
        EventLog.log(.travelCleanup,
                     "merged \(summary.tripsMerged), collapsed \(summary.staysCollapsed), removed \(summary.orphansRemoved)",
                     context: modelContext)
        if summary.isEmpty {
            return .init(text: "Travel data is already clean — no overlapping trips, duplicate stays, or orphaned rows.")
        }
        var parts: [String] = []
        if summary.tripsMerged > 0 { parts.append("merged \(summary.tripsMerged) overlapping trip(s)") }
        if summary.staysCollapsed > 0 { parts.append("collapsed \(summary.staysCollapsed) duplicate stay(s)") }
        if summary.orphansRemoved > 0 { parts.append("removed \(summary.orphansRemoved) orphaned row(s)") }
        return .init(text: "Cleaned up travel data: " + parts.joined(separator: ", ")
                     + ". Back-to-back trips sharing a boundary day were left alone.")
    }

    @MainActor
    private func toolAddJourney(_ input: [String: Any]) async -> JeevesChatService.ToolResult {
        let tripQuery = input["trip"] as? String ?? ""
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
        // No silent trips.last fallback — a journey landing in an arbitrary
        // trip is the same wrong-home bug as the merged-Mysore stay.
        guard let trip = JeevesChatService.bestMatches(trips, title: \.title, query: tripQuery).first else {
            if trips.isEmpty {
                return .init(text: "No trips exist yet — create one with add_trip first.")
            }
            let names = trips.map { "'\($0.title)' (\(TravelGuard.dayRange($0)))" }.joined(separator: ", ")
            return .init(text: "No trip matches '\(tripQuery)'. Existing: \(names). Name one of them, or create the right trip with add_trip.")
        }
        let mode = TravelMode(rawValue: input["mode"] as? String ?? "flight") ?? .flight
        guard let minute = minutesFrom(input["time"] as? String) else {
            return .init(text: "Need a 24-hour HH:MM time.")
        }
        // Same >6 h rule as the editor: a given travel_minutes can't smuggle a
        // road trip into a flight's door-to-terminal slot. Nothing is created.
        if mode != .drive, let given = input["travel_minutes"] as? Int,
           !LeaveBy.plausibleFlightJourney(given) {
            return .init(text: "\(given) min (\(LeaveBy.hours(given))) by road isn't a door-to-airport run — I didn't add this. Give me the real airport-run minutes, or add the road leg as a drive and the flight separately.")
        }
        // A missing date used to default to TODAY — a return drive weeks out
        // once got its leave-by computed for this afternoon. Never guess.
        guard let dateRaw = input["date"] as? String, !dateRaw.isEmpty else {
            return .init(text: "Which date is this journey on? Pass date (YYYY-MM-DD) — I won't assume today.")
        }
        let day = JeevesChatService.resolveDate(dateRaw, relativeTo: today)
        // A flight's time is its departure, read at the ORIGIN airport ("19:40
        // leaving Singapore" is 19:40 SGT). A drive's time is its arrival
        // deadline, read at the DESTINATION ("reach the lodge by 13:00" is
        // 13:00 where the lodge is) — the same convention as the editor and
        // the card, which briefly disagreed with this tool.
        let fromZoneID = input["from_timezone"] as? String ?? ""
        let toZoneID = input["to_timezone"] as? String ?? ""
        let fromZone = TimeZone(identifier: fromZoneID) ?? .current
        let toZone = TimeZone(identifier: toZoneID) ?? .current
        let wall = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60,
                                         second: 0, of: day) ?? day
        let when = TravelClock.instant(readingWallClock: wall, in: mode == .drive ? toZone : fromZone)

        // Optional scheduled arrival, on the destination's clock.
        var arriveAt: Date? = nil
        if let aMin = minutesFrom(input["arrive_time"] as? String) {
            let aDay = JeevesChatService.resolveDate(input["arrive_date"] as? String ?? input["date"] as? String,
                                                     relativeTo: today)
            if let aWall = Calendar.current.date(bySettingHour: aMin / 60, minute: aMin % 60,
                                                 second: 0, of: aDay) {
                arriveAt = TravelClock.instant(readingWallClock: aWall, in: toZone)
            }
        }

        let newTo = input["to"] as? String ?? ""
        let newFrom = input["from"] as? String ?? ""
        // UPSERT, not insert: "leave at 9 instead" is a correction, and every
        // correction turn used to mint another journey — one conversation
        // left four outbound drives to the same waterfall, each with its own
        // dawn nudge. Same trip + mode + anchor day + same destination means
        // the same leg: update it.
        let anchorDay = Calendar.current.startOfDay(for: when)
        let allSegs = (try? modelContext.fetch(FetchDescriptor<TravelSegment>())) ?? []
        // A FLIGHT NUMBER identifies the leg on its own. Matching on
        // destination text let the same flight land twice — "UL 174 to
        // Colombo" and "UL 174 to Bandaranaike Airport" are one aircraft, but
        // the strings don't overlap, so a restatement minted a second leg that
        // both the upsert and the trajectory duplicate-check missed.
        let newLabel = TravelSegment.normalizedFlightNumber(input["label"] as? String ?? "")
        let sameFlight = allSegs.first { s in
            s.tripID == trip.id && s.mode == mode && mode != .drive && !newLabel.isEmpty
                && TravelSegment.normalizedFlightNumber(s.label) == newLabel
        }
        let sameLeg = sameFlight ?? allSegs.first { s in
            s.tripID == trip.id && s.mode == mode
                && Calendar.current.isDate(mode == .drive ? (s.arriveBy ?? .distantPast) : s.departAt,
                                           inSameDayAs: anchorDay)
                && (s.toPlace.localizedCaseInsensitiveContains(newTo)
                    || newTo.localizedCaseInsensitiveContains(s.toPlace))
                && !s.toPlace.isEmpty && !newTo.isEmpty
        }
        let updating = sameLeg != nil
        let segment: TravelSegment
        if let sameLeg {
            segment = sameLeg
            segment.label = input["label"] as? String ?? segment.label
            segment.fromPlace = newFrom.isEmpty ? segment.fromPlace : newFrom
            segment.toPlace = newTo
            if mode == .drive { segment.arriveBy = when } else { segment.departAt = when }
            segment.arriveAt = mode == .drive ? nil : (arriveAt ?? segment.arriveAt)
            if !fromZoneID.isEmpty { segment.fromTimeZoneID = fromZoneID }
            if !toZoneID.isEmpty { segment.toTimeZoneID = toZoneID }
            if let v = input["check_in_minutes"] as? Int { segment.checkInMinutes = v }
            if let v = input["security_minutes"] as? Int { segment.securityMinutes = v }
            if let v = input["buffer_minutes"] as? Int { segment.bufferMinutes = v }
            if let v = input["stop_minutes"] as? Int { segment.stopMinutes = v }
            if let v = input["travel_minutes"] as? Int {
                segment.travelMinutes = v
                segment.travelIsEstimated = true
            }
        } else {
            segment = TravelSegment(
                tripID: trip.id, mode: mode,
                label: input["label"] as? String ?? "",
                fromPlace: newFrom,
                toPlace: newTo,
                departAt: mode == .drive ? .distantPast : when,
                arriveBy: mode == .drive ? when : nil,
                arriveAt: mode == .drive ? nil : arriveAt,
                fromTimeZoneID: fromZoneID,
                toTimeZoneID: toZoneID,
                checkInMinutes: input["check_in_minutes"] as? Int ?? (mode == .drive ? 0 : 180),
                securityMinutes: input["security_minutes"] as? Int ?? (mode == .drive ? 0 : 30),
                bufferMinutes: input["buffer_minutes"] as? Int ?? 20,
                stopMinutes: input["stop_minutes"] as? Int ?? 0,
                travelMinutes: input["travel_minutes"] as? Int ?? 0)
            modelContext.insert(segment)
        }

        // Measure the journey now if we can — a leave-by built on a guess is
        // exactly the failure this feature exists to prevent.
        var measured = false
        var refusedRoadMinutes = 0
        if segment.travelMinutes == 0, !segment.toPlace.isEmpty {
            let saved = (try? modelContext.fetch(FetchDescriptor<SavedLocation>())) ?? []
            let originRaw = segment.fromPlace.isEmpty ? "Home" : segment.fromPlace
            let origin = saved.first { $0.kind.rawValue.lowercased() == originRaw.lowercased() }
                .map(\.address).flatMap { $0.isEmpty ? nil : $0 } ?? originRaw
            if let m = await commuteMinutes(origin, segment.toPlace,
                                            max(when.addingTimeInterval(-3600), Date())) {
                // Same guard as the editor and the card: days of road time in
                // a flight's door-to-terminal slot means `to` isn't an airport
                // — refuse it, or absorb would grow the trip around a chain
                // that leaves days early.
                if mode != .drive && m > 360 {
                    refusedRoadMinutes = m
                } else {
                    segment.travelMinutes = m
                    segment.travelIsEstimated = false
                    measured = true
                }
            }
        }
        modelContext.saveOrLog("chat.addJourney")
        // Same rule as the editor and the card: a journey's days belong to its
        // trip. Without this, a chat-added two-day drive computed a leave day
        // outside the trip window and its card rendered on no day at all.
        let widened = await TravelGuard.absorb(segment, context: modelContext)
        if scheduleNudges { await TravelNotifier.schedule(segment: segment) }

        guard let plan = LeaveBy.plan(for: segment) else {
            return .init(text: "Journey saved, but I need \(mode == .drive ? "an arrival" : "a departure") time to compute a leave-by.")
        }
        let leaveLabel = TravelClock.hhmm(plan.leaveAt, in: fromZone)
            + (fromZoneID.isEmpty ? "" : " " + TravelClock.label(fromZone, at: plan.leaveAt))
        let caveat: String
        if refusedRoadMinutes > 0 {
            caveat = " I measured \(refusedRoadMinutes) min by ROAD to '\(segment.toPlace)' — that's not a door-to-airport run, so I ignored it. Give me the departure airport (or the real airport-run minutes) and I'll redo this."
        } else if segment.travelMinutes == 0 {
            caveat = " I couldn't measure the journey — tell me roughly how long it takes and I'll redo this."
        } else if measured {
            caveat = " Journey measured against live traffic (\(segment.travelMinutes) min)."
        } else {
            caveat = " Journey time \(segment.travelMinutes) min as given."
        }
        let windowNote = widened
            ? " The trip's dates grew to cover the journey days (the planner stands down on them)."
            : ""
        // No nudge is scheduled for a chain with no journey time — don't
        // promise one.
        let nudge = segment.travelMinutes > 0 ? " I'll nudge you 30 minutes before." : ""
        // A foreign flight saved without zone stamps silently reads its times
        // on the device clock (IST) — surface it so the model corrects the leg.
        let zoneNote = (mode != .drive && (fromZoneID.isEmpty || toZoneID.isEmpty))
            ? " NOTE: no timezones stamped on this leg — its clocks assume the device zone. For an international flight, call add_journey again with from_timezone and to_timezone (IANA IDs) to correct it."
            : ""
        return .init(text: "\(updating ? "Updated the existing" : "Added to \(trip.title):") "
                     + "\(segment.label.isEmpty ? mode.label : segment.label). "
                     + "Leave at \(leaveLabel) on \(Self.dayString(day)).\(caveat)\(windowNote)\(nudge)\(zoneNote)")
    }

    // MARK: History + standing preferences

    @MainActor
    private func toolFetchChatHistory(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let daysBack = input["days_back"] as? Int ?? 7
        let query = input["query"] as? String
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(1, daysBack), to: Date()) ?? Date()
        var rows = allTurns.filter { $0.timestamp >= cutoff && !$0.content.isEmpty }
        if let query, !query.isEmpty {
            rows = rows.filter { JeevesChatService.fuzzyMatch($0.content, query: query) }
        }
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
        let capped = rows.suffix(80).map {
            ["t": f.string(from: $0.timestamp), "role": $0.roleRaw,
             "text": String($0.content.prefix(200))]
        }
        let obj: [String: Any] = ["count": rows.count, "shown": capped.count, "turns": capped]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return .init(text: String(data: data, encoding: .utf8) ?? "{}")
    }

    @MainActor
    private func toolRememberPreference(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let note = input["note"] as? String ?? ""
        guard !note.isEmpty else { return .init(text: "Preference note was empty.") }
        if input["forget"] as? Bool == true {
            let removed = StandingPrefs.forget(matching: note)
            return .init(text: removed > 0 ? "Forgot \(removed) preference(s) matching '\(note)'."
                                           : "No stored preference matches '\(note)'.")
        }
        StandingPrefs.add(note, expires: input["expires"] as? String)
        return .init(text: "Remembered: '\(note)'\((input["expires"] as? String).map { " (until \($0))" } ?? ""). Current standing preferences: \(StandingPrefs.all().joined(separator: " | ")).")
    }

    // MARK: fetch_app_data — the read side of the chat

    /// Serves a compact JSON snapshot of one collection so the model can answer
    /// data questions (PRs, missing venues, programme structure) by filtering
    /// the rows itself. Fresh fetches, not @Query snapshots.
    @MainActor
    private func toolFetchAppData(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let collection = input["collection"] as? String ?? ""
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dtf = DateFormatter()
        dtf.dateFormat = "yyyy-MM-dd HH:mm"

        func json(_ rows: [[String: Any]]) -> JeevesChatService.ToolResult {
            let obj: [String: Any] = ["count": rows.count, "rows": rows]
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            return .init(text: String(data: data, encoding: .utf8) ?? "{}")
        }

        switch collection {
        case "run_program":
            return .init(text: JeevesChatService.runProgramSummary())

        case "events":
            let all = (try? modelContext.fetch(FetchDescriptor<DailyEvent>())) ?? []
            return json(all.sorted { $0.date < $1.date }.map { e in
                [
                    "date": df.string(from: e.date),
                    "title": e.title,
                    "start": e.isAllDay ? "all-day" : hhmm(e.startMinute),
                    "end": e.isAllDay ? "all-day" : hhmm(e.endMinute),
                    "venue": e.destinationAddress,
                    "hasLocation": !e.destinationAddress.isEmpty || e.destinationLat != nil,
                ]
            })

        case "workouts":
            let all = (try? modelContext.fetch(FetchDescriptor<Workout>())) ?? []
            return json(all.sorted { $0.date > $1.date }.map { w in
                [
                    "date": df.string(from: w.date),
                    "type": w.typeRaw, "state": w.stateRaw, "source": w.sourceRaw,
                    "title": w.title, "durationMin": w.durationMin, "avgBPM": w.avgBPM,
                    "distanceKm": w.distanceKm, "inclinePercent": w.inclinePercent,
                ]
            })

        case "lifts":
            let sessions = (try? modelContext.fetch(FetchDescriptor<LiftSession>())) ?? []
            let sets = (try? modelContext.fetch(FetchDescriptor<LiftSet>())) ?? []
            return json(sessions.sorted { $0.date > $1.date }.map { s in
                let ss = sets.filter { $0.sessionID == s.id }.sorted { $0.order < $1.order }
                return [
                    "date": df.string(from: s.date),
                    "exercise": s.exerciseName,
                    "tonnageKg": Int(LiftMath.sessionTonnage(ss).rounded()),
                    "sets": ss.map { set in
                        ["reps": set.reps, "kg": set.weightKg, "type": set.inputTypeRaw,
                         "addedKg": set.addedKg, "holdSec": set.holdSeconds]
                    },
                ]
            })

        case "runs":
            let all = (try? modelContext.fetch(FetchDescriptor<RunSession>())) ?? []
            return json(all.sorted { $0.date > $1.date }.map { r in
                ["date": df.string(from: r.date), "week": r.weekIndex + 1,
                 "durationMin": r.durationSec / 60, "distanceKm": r.distanceKm,
                 "avgHR": r.avgHeartRate ?? 0, "rpe": r.rpe]
            })

        case "todos":
            let all = (try? modelContext.fetch(FetchDescriptor<Todo>())) ?? []
            return json(all.map { t in
                ["title": t.title, "priority": t.priorityRaw,
                 "due": t.dueDate.map(df.string(from:)) ?? "",
                 "done": t.doneAt != nil]
            })

        case "reminders":
            let all = (try? modelContext.fetch(FetchDescriptor<Reminder>())) ?? []
            return json(all.sorted { $0.fireAt < $1.fireAt }.map { r in
                ["title": r.title, "fireAt": dtf.string(from: r.fireAt),
                 "recurrence": r.recurrenceRaw, "enabled": r.enabled,
                 "completed": r.completedAt != nil]
            })

        case "checkins":
            let all = (try? modelContext.fetch(FetchDescriptor<CheckIn>())) ?? []
            return json(all.sorted { $0.date > $1.date }.map { c in
                ["date": df.string(from: c.date), "workedOut": c.workedOut,
                 "weight": c.weightTraining, "stretch": c.stretching,
                 "mobility": c.mobility, "cardio": c.cardio,
                 "cardioType": c.cardioType ?? "",
                 "cardioMin": c.cardioDuration ?? 0, "incline": c.cardioIncline ?? 0]
            })

        case "books":
            let all = (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
            return json(all.map { b in
                ["title": b.title, "author": b.author,
                 "status": String(describing: b.status),
                 "page": b.currentPage, "totalPages": b.totalPages ?? 0]
            })

        default:
            return .init(text: "Unknown collection '\(collection)'. Valid: events, workouts, lifts, runs, run_program, todos, reminders, checkins, books.")
        }
    }

    // MARK: Task capture (todo + reminder)

    @MainActor
    private func toolAddTodo(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let title = (input["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .init(text: "Todo needs a title.") }
        let priority = TodoPriority(rawValue: input["priority"] as? String ?? "") ?? .medium
        let due = (input["due_date"] as? String).map {
            JeevesChatService.resolveDate($0, relativeTo: Date())
        }
        let openCount = ((try? modelContext.fetch(FetchDescriptor<Todo>())) ?? [])
            .filter { $0.doneAt == nil }.count
        let todo = Todo(title: title, priority: priority, sortOrder: -openCount - 1)
        todo.dueDate = due
        modelContext.insert(todo)
        modelContext.saveOrLog()
        return .init(text: "Added todo '\(title)' (\(priority.rawValue))\(due.map { d in ", due \(Self.dayString(d))" } ?? "").")
    }

    @MainActor
    private func toolAddReminder(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let title = (input["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let time = input["time"] as? String ?? ""
        guard !title.isEmpty, !time.isEmpty else { return .init(text: "Reminder needs a title and a time.") }
        let fire = JeevesChatService.resolveFireDate(dateRaw: input["date"] as? String,
                                                    timeRaw: time, relativeTo: Date())
        let recurrence = ReminderRecurrence(rawValue: input["recurrence"] as? String ?? "") ?? .once
        let dtf = DateFormatter()
        dtf.dateFormat = "EEE d MMM, HH:mm"

        // Asking twice must not nag twice (eval finding: a repeated "pack
        // binoculars" minted a second identical reminder). Same title on an
        // active reminder → move it to the new time instead of duplicating.
        let all = (try? modelContext.fetch(FetchDescriptor<Reminder>())) ?? []
        if let existing = all.first(where: {
            $0.isActive && $0.title.lowercased() == title.lowercased()
        }) {
            let moved = existing.fireAt != fire
            existing.fireAt = fire
            existing.recurrence = recurrence
            modelContext.saveOrLog()
            ReminderScheduler.reschedule(all.filter(\.isActive))
            return .init(text: moved
                ? "That reminder already existed — moved '\(title)' to \(dtf.string(from: fire))."
                : "'\(title)' is already set for \(dtf.string(from: fire)) — nothing to add.")
        }

        let reminder = Reminder(title: title, fireAt: fire, recurrence: recurrence)
        modelContext.insert(reminder)
        modelContext.saveOrLog()
        ReminderScheduler.reschedule((all + [reminder]).filter(\.isActive))
        return .init(text: "Reminder set: '\(title)' at \(dtf.string(from: fire)) (\(recurrence.rawValue)).")
    }

    private static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }

    /// Re-plan only the rest of today from now, preserving what's already done —
    /// the deviation path (a late event, an overrun commute, "I'm behind").
    @MainActor
    private func toolReplanToday(_ input: [String: Any]) async -> JeevesChatService.ToolResult {
        let note = (input["note"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        // A trip owns its days — no generator may plan one.
        if let trip = TravelGuard.tripCovering(today, context: modelContext) {
            return .init(text: TravelGuard.refusalMessage(for: today, trip: trip))
        }
        let state = planState(on: today)
        guard let committed = state.plan else {
            return .init(text: "There's no plan for today yet, so there's nothing to re-plan. Offer to plan the day first.")
        }
        let c = Calendar.current
        let nowMinute = c.component(.hour, from: Date()) * 60 + c.component(.minute, from: Date())
        // Past the 20:30 work boundary there's no work day left to re-shape —
        // the rest is wind-down and sleep. Decline gracefully rather than ask the
        // planner for an impossible "from 21:00 to 20:30" window.
        guard nowMinute < 20 * 60 + 30 else {
            return .init(text: "It's past the 20:30 work boundary, so the work day is done — the rest of the evening is wind-down and sleep. Tell the user there's nothing left to re-plan tonight; offer to sort out tomorrow instead.")
        }
        // Preserve everything already finished — but ELAPSED IS NOT DONE. A
        // lateness replan locked "Gym — Mobility" as completed while the user
        // sat in traffic; the model now names the blocks that didn't happen
        // (missed_blocks) and they're excluded from the locked set and told
        // to the planner as missed.
        let missed = (input["missed_blocks"] as? [Any])?.compactMap { $0 as? String } ?? []
        var locked = PlanCoordinator.lockedBlocks(committed, endedBy: nowMinute)
        if !missed.isEmpty {
            locked = locked.filter { block in
                !missed.contains { JeevesChatService.strictMatch(block.title, query: $0) }
            }
        }
        let doneNote = locked.map(\.title).joined(separator: ", ")
        let missedNote = missed.isEmpty ? "" : " Earlier blocks that did NOT happen (do not count them as done): \(missed.joined(separator: ", "))."

        // The remainder starts at the user's stated ETA when they gave one
        // ("20 more minutes"), not at the clock — a plan that begins before
        // the user can act is already behind on arrival.
        let resumeMinute = minutesFrom(input["resume_at"] as? String).map { max($0, nowMinute) } ?? nowMinute

        let result = await PlanCoordinator.generateLogged(.init(
            userMessage: note + missedNote,
            hasGym: state.hasGymToday,
            gymMinute: state.gymMinute,
            events: eventsOn(today),
            locations: locations,
            prepSessions: prepSessions,
            routine: Baseline.routine(from: routineActivities),
            adherenceNote: AdherenceHistory.planningNote(context: modelContext, for: today),
            replanFromMinute: resumeMinute,
            alreadyDoneNote: doneNote.isEmpty ? nil : doneNote,
            lockedBlocks: locked,
            planDate: today
        ), context: modelContext, trigger: .chat)

        guard !result.isOffline else {
            return .init(text: "Couldn't reach the planner to re-plan — your current schedule is unchanged.\(result.error.map { " (\($0))" } ?? "")")
        }
        commitPlan(result.plan, isOffline: false, on: today)
        await NotificationService.notifyPlanReady(isOffline: false)
        return .init(text: "Re-planned from \(hhmm(nowMinute)), keeping what you'd already done. \(result.plan.summary)",
                     plan: result.plan, isOfflinePlan: false)
    }

    @MainActor
    private func toolFetchCalendar(_ input: [String: Any]) async -> JeevesChatService.ToolResult {
        let date = JeevesChatService.resolveDate(input["date"] as? String, relativeTo: today)
        guard KeychainService.isGoogleCalendarConnected else {
            return .init(text: "Google Calendar isn't connected. Tell the user to connect it in Plan setup (the calendar button), then try again.")
        }
        do {
            let events = try await GoogleCalendarService.events(on: date)
            guard !events.isEmpty else {
                return .init(text: "No timed events on the user's calendar for \(dayLabel(date)).")
            }
            let lines = events.map { e in
                "• \(e.title) \(hhmm(e.startMinute))–\(hhmm(e.endMinute))" + (e.location.isEmpty ? "" : " at \(e.location)")
            }.joined(separator: "\n")
            return .init(text: "Calendar events for \(dayLabel(date)):\n\(lines)\n\nRead these back to the user and confirm before adding any with add_event.")
        } catch {
            return .init(text: "Couldn't read the calendar: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func toolAddEvent(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let date = JeevesChatService.resolveDate(input["date"] as? String, relativeTo: today)
        let title = (input["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, let startStr = input["start_time"] as? String,
              let start = GeneratedBlock.minutes(from: startStr) else {
            return .init(text: "Couldn't add it — I need a title and a start time. Ask the user for whatever's missing.")
        }
        let givenEnd = (input["end_time"] as? String).flatMap(GeneratedBlock.minutes(from:))
        // Clamp the assumed end to the day: an unclamped 3 h default stored
        // "23:00–26:00", and edit_event (which clamps at 24:00) then turned
        // "extend it by an hour" into a two-hour SHRINK.
        let end = givenEnd ?? min(24 * 60, start + 180)
        let venue = (input["venue"] as? String) ?? ""
        let from = LocationKind(rawValue: (input["leaving_from"] as? String) ?? "Home") ?? .home
        if eventsOn(date).contains(where: { $0.title.lowercased() == title.lowercased() }) {
            return .init(text: "\"\(title)\" is already on \(dayLabel(date)); didn't add a duplicate.")
        }
        let event = DailyEvent(
            date: date, title: title, startMinute: start, endMinute: end,
            destinationAddress: venue, outboundStart: from, source: .manual
        )
        modelContext.insert(event)
        modelContext.saveOrLog()
        resolveEventDestinationIfLink(event)
        let venueSuffix: String
        if venue.isEmpty { venueSuffix = "" }
        else if GoogleMapsService.isMapsLink(venue) { venueSuffix = " — identifying the location…" }
        else { venueSuffix = " at \(venue)" }
        // An ASSUMED end time must announce itself: the model later "extended"
        // a dinner by an hour and shortened it, because it never knew the 3 h
        // default had been applied.
        let assumed = givenEnd == nil
            ? " (no end time given — I assumed it ends \(hhmm(end)); change it with edit_event's extend_by_minutes)"
            : ""
        return .init(text: "Added \"\(title)\" \(hhmm(start))–\(hhmm(end)) on \(dayLabel(date))\(venueSuffix).\(assumed)")
    }

    /// If an event's venue was pasted as a Google Maps link, identify the place
    /// in the background and replace the opaque URL with its full address + pin.
    @MainActor
    func resolveEventDestinationIfLink(_ event: DailyEvent) {
        let raw = event.destinationAddress
        guard !raw.isEmpty, event.destinationLat == nil else { return }
        Task {
            // A pasted Maps link resolves to its pin; anything the user TYPED or
            // SPOKE is geocoded as free text. Without the second path a venue
            // name has no coordinates and no journey can be measured to it —
            // which is how a 265 km drive once got planned as a 30-min commute.
            let place = GoogleMapsService.isMapsLink(raw)
                ? await GoogleMapsService.resolvePlace(raw)
                : await GoogleMapsService.geocodePlace(raw)
            guard let place, place.lat != nil else { return }
            event.destinationAddress = place.displayAddress
            event.destinationLat = place.lat
            event.destinationLng = place.lng
            modelContext.saveOrLog()
        }
    }

    @MainActor
    private func toolSetGym(_ input: [String: Any]) -> JeevesChatService.ToolResult {
        let date = JeevesChatService.resolveDate(input["date"] as? String, relativeTo: today)
        let gymToday = input["gym_today"] as? Bool ?? false
        let state = planState(on: date)
        state.hasGymToday = gymToday
        if gymToday {
            if let gt = (input["gym_time"] as? String).flatMap(GeneratedBlock.minutes(from:)) { state.gymMinute = gt }
            modelContext.saveOrLog()
            let at = state.gymMinute.map { " at \(hhmm($0))" } ?? " (no time set — ask when weightlifting starts)"
            return .init(text: "Gym set for \(dayLabel(date))\(at).")
        } else {
            state.gymMinute = nil
            modelContext.saveOrLog()
            return .init(text: "Cleared the gym for \(dayLabel(date)).")
        }
    }

    @MainActor
    private func toolPlanDay(_ input: [String: Any]) async -> JeevesChatService.ToolResult {
        let date = JeevesChatService.resolveDate(input["date"] as? String, relativeTo: today)
        // A trip owns its days — no generator may plan one.
        if let trip = TravelGuard.tripCovering(date, context: modelContext) {
            EventLog.log(.planRefusedTravel, "chat plan_day refused (\(trip.title))", context: modelContext)
            return .init(text: TravelGuard.refusalMessage(for: date, trip: trip))
        }
        let note = (input["note"] as? String) ?? ""
        let state = planState(on: date)
        let result = await PlanCoordinator.generateLogged(.init(
            userMessage: note,
            hasGym: state.hasGymToday,
            gymMinute: state.gymMinute,
            events: eventsOn(date),
            locations: locations,
            prepSessions: prepSessions,
            routine: Baseline.routine(from: routineActivities),
            adherenceNote: AdherenceHistory.planningNote(context: modelContext, for: date),
            planDate: date
        ), context: modelContext, trigger: .chat)
        commitPlan(result.plan, isOffline: result.isOffline, on: date)
        await NotificationService.notifyPlanReady(isOffline: result.isOffline)
        let summary = result.isOffline
            ? "Built an offline plan for \(dayLabel(date)) — couldn't reach the planning service.\(result.error.map { " (\($0))" } ?? "")"
            : "Planned \(dayLabel(date)). \(result.plan.summary)"
        return .init(text: summary, plan: result.plan, isOfflinePlan: result.isOffline)
    }

    // MARK: Tool context helpers

    /// Fresh fetch (not the @Query snapshot) so a plan_day call sees events an
    /// add_event call created earlier in the same agentic turn.
    private func eventsOn(_ date: Date) -> [DailyEvent] {
        let day = date.startOfDay
        let all: [DailyEvent] = (try? modelContext.fetch(FetchDescriptor<DailyEvent>())) ?? []
        return all.filter { $0.date == day }.sorted { $0.startMinute < $1.startMinute }
    }

    /// The DailyPlanState for a day, creating one if needed.
    private func planState(on date: Date) -> DailyPlanState {
        DailyPlanState.fetchOrCreate(for: date, in: modelContext)
    }

    /// A one-line summary of today's anchors, given to the model so it knows
    /// what's already set before deciding whether to add or plan.
    func stateNote() -> String {
        var lines: [String] = []
        let e = eventsOn(today)
        lines.append(e.isEmpty
            ? "Today has no events set."
            : "Today's events: " + e.map { "\($0.title) \(hhmm($0.startMinute))–\(hhmm($0.endMinute))" }.joined(separator: "; ") + ".")
        if let s = todayPlanState, s.hasGymToday {
            lines.append("Gym today" + (s.gymMinute.map { " at \(hhmm($0))" } ?? "") + ".")
        } else {
            lines.append("No gym set for today.")
        }
        if todayPlanState?.plan != nil { lines.append("A plan for today already exists — planning again replaces it.") }
        let prefs = StandingPrefs.all()
        if !prefs.isEmpty {
            lines.append("STANDING PREFERENCES (persist across days; honor without re-asking): "
                         + prefs.map { "\u{2022} \($0)" }.joined(separator: " "))
        }
        return "CURRENT STATE (today = \(dayLabel(today))):\n" + lines.joined(separator: "\n")
    }

    private func dayLabel(_ date: Date) -> String {
        let day = date.startOfDay
        if day == today { return "today" }
        if day == Calendar.current.date(byAdding: .day, value: 1, to: today) { return "tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f.string(from: day)
    }

    /// Saves the generated plan onto today's DailyPlanState so the Day Planner
    /// tab shows it and it survives relaunches.
    func commitPlan(_ plan: GeneratedPlan, isOffline: Bool, on date: Date) {
        let day = date.startOfDay
        // Fresh-fetch (via planState), NOT the @Query snapshot: inside one
        // agentic turn the view never re-renders, so `dailyPlans` predates the
        // state a set_gym/plan_day tool already inserted for this day. Reading
        // the stale snapshot here would insert a SECOND DailyPlanState — a
        // duplicate row that also splits the gym flag and the plan across two
        // records.
        let state = planState(on: day)
        state.storePlan(plan, isOffline: isOffline)
        modelContext.saveOrLog()
        // Schedule on-device reminders for this plan's key blocks.
        Task { await NotificationService.reschedule(plan: plan, on: day) }
        // Arm a background traffic re-check ~90 min before the next commute.
        CommuteBackgroundRefresh.scheduleNext(context: modelContext)
    }

}
