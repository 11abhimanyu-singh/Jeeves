//
//  ProductMetrics.swift
//  Jeeves
//
//  Three numbers that say whether Jeeves is actually getting better, computed
//  from what the app already records. Anomaly counts say "nothing is broken";
//  these say "it's doing its job well" — a different question, and the one
//  worth trending.
//
//    correctionRate   — of the state-changing things chat did, how many were
//                       fixing something it had just done? Falling = it gets
//                       the request right the first time.
//    replanAcceptance — of days that got a plan, how many kept the first one?
//                       Rising = plans survive contact with the day.
//    timeToOutcome    — median minutes from the first message of a session to
//                       the last change it made. Falling = less back-and-forth
//                       per outcome.
//
//  Pure functions over plain snapshots (no SwiftData in the math), so every
//  definition is pinned by tests and the same code can run over an exported
//  state file. Small samples are reported as such rather than as confident
//  percentages — three data points is not a trend.
//

import Foundation
import SwiftData

struct MetricValue: Codable, Sendable {
    var value: Double?          // nil when there isn't enough data to claim one
    var sampleSize: Int
    var note: String            // human sentence for the digest

    var isConfident: Bool { value != nil && sampleSize >= 5 }
}

struct ProductMetricsSnapshot: Codable, Sendable {
    var windowDays: Int
    var correctionRate: MetricValue
    var replanAcceptance: MetricValue
    var timeToOutcomeMinutes: MetricValue
}

enum ProductMetrics {

    // MARK: Plain snapshots (what the math actually needs)

    struct ToolCallRecord: Sendable {
        var date: Date
        var toolName: String
        var subject: String     // subjectID, or "" when the tool didn't name one
    }

    struct GenerationRecord: Sendable {
        var startedAt: Date
        var succeeded: Bool
        /// The overnight auto-planner fills several days in one night, so its
        /// runs would read as "replans" of the night it ran. Acceptance is
        /// about plans the USER asked for and then kept.
        var isUserRequested: Bool
    }

    struct SessionTurn: Sendable {
        var date: Date
        var isUser: Bool
    }

    /// Tools that CHANGE something (the denominator for corrections) and, of
    /// those, the ones that only ever exist to fix a previous action.
    static let mutatingTools: Set<String> = [
        "add_event", "edit_event", "delete_event", "set_gym", "plan_day", "replan_today",
        "add_todo", "complete_todo", "delete_todo", "add_reminder", "delete_reminder",
        "log_walk", "mark_block_done", "remember_preference",
        "add_trip", "update_trip", "delete_trip", "add_journey", "delete_journey",
        "add_stay", "update_stay", "delete_stay", "clean_travel_data",
    ]

    /// A call is a CORRECTION when it edits or deletes something, or repeats a
    /// create for a subject already touched, within the correction window.
    static let correctingTools: Set<String> = [
        "edit_event", "delete_event", "delete_todo", "delete_reminder",
        "update_trip", "delete_trip", "delete_journey", "update_stay", "delete_stay",
        "clean_travel_data", "replan_today",
    ]

    static let correctionWindow: TimeInterval = 45 * 60
    static let sessionGap: TimeInterval = 45 * 60

    // MARK: 1 · Correction rate

    /// Share of mutating tool calls that were fixing recent work. A correction
    /// counts when the tool exists only to correct, OR when the same tool hits
    /// the same subject twice inside the window (the "iterate by re-creating"
    /// pattern that once minted three trips for one day trip).
    static func correctionRate(_ calls: [ToolCallRecord]) -> MetricValue {
        let mutating = calls
            .filter { mutatingTools.contains($0.toolName) }
            .sorted { $0.date < $1.date }
        guard !mutating.isEmpty else {
            return MetricValue(value: nil, sampleSize: 0,
                               note: "No changes made through chat yet.")
        }
        var corrections = 0
        for (i, call) in mutating.enumerated() {
            if correctingTools.contains(call.toolName) {
                corrections += 1
                continue
            }
            // A repeat of the same create on the same subject inside the
            // window is the same user still trying to get it right.
            let repeated = mutating[..<i].contains {
                $0.toolName == call.toolName
                    && !call.subject.isEmpty && $0.subject == call.subject
                    && call.date.timeIntervalSince($0.date) <= correctionWindow
            }
            if repeated { corrections += 1 }
        }
        let rate = Double(corrections) / Double(mutating.count)
        return MetricValue(
            value: rate, sampleSize: mutating.count,
            note: "\(corrections) of \(mutating.count) chat changes were corrections"
                + (mutating.count < 5 ? " (too few to call a trend yet)." : "."))
    }

    // MARK: 2 · Replan acceptance

    /// Share of planned days whose FIRST successful plan was never regenerated.
    /// A day replanned once is not a failure — but the trend across days is the
    /// signal that plans are landing right the first time.
    static func replanAcceptance(_ generations: [GenerationRecord]) -> MetricValue {
        let byDay = Dictionary(grouping: generations.filter { $0.succeeded && $0.isUserRequested }) {
            Calendar.current.startOfDay(for: $0.startedAt)
        }
        guard !byDay.isEmpty else {
            return MetricValue(value: nil, sampleSize: 0, note: "No plans generated yet.")
        }
        let kept = byDay.values.filter { $0.count == 1 }.count
        let rate = Double(kept) / Double(byDay.count)
        return MetricValue(
            value: rate, sampleSize: byDay.count,
            note: "\(kept) of \(byDay.count) planned days kept their first plan"
                + (byDay.count < 5 ? " (early days)." : "."))
    }

    // MARK: 3 · Time to outcome

    /// Median minutes from a session's first user message to the last change
    /// it produced. Sessions split on a 45-minute gap (same rule the chat eval
    /// uses). Sessions that changed nothing are excluded — they're questions,
    /// not outcomes.
    static func timeToOutcome(turns: [SessionTurn], calls: [ToolCallRecord]) -> MetricValue {
        let ordered = turns.sorted { $0.date < $1.date }
        guard !ordered.isEmpty else {
            return MetricValue(value: nil, sampleSize: 0, note: "No conversations yet.")
        }
        // Split into sessions.
        var sessions: [[SessionTurn]] = []
        var current: [SessionTurn] = []
        for turn in ordered {
            if let last = current.last, turn.date.timeIntervalSince(last.date) > sessionGap {
                sessions.append(current)
                current = []
            }
            current.append(turn)
        }
        if !current.isEmpty { sessions.append(current) }

        let mutating = calls.filter { mutatingTools.contains($0.toolName) }
        var durations: [Double] = []
        for session in sessions {
            guard let first = session.first(where: \.isUser)?.date,
                  let end = session.last?.date else { continue }
            // The last change made inside this session's span (allowing the
            // tool call to land slightly after the final turn).
            let window = first...(end.addingTimeInterval(5 * 60))
            guard let lastChange = mutating.filter({ window.contains($0.date) }).map(\.date).max()
            else { continue }
            durations.append(lastChange.timeIntervalSince(first) / 60)
        }
        guard !durations.isEmpty else {
            return MetricValue(value: nil, sampleSize: 0,
                               note: "No conversation has produced a change yet.")
        }
        let sorted = durations.sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return MetricValue(
            value: median, sampleSize: sorted.count,
            note: "median \(String(format: "%.0f", median)) min from asking to done across \(sorted.count) session(s)"
                + (sorted.count < 5 ? " (early days)." : "."))
    }

    // MARK: Store → snapshot

    /// Compute all three over the trailing window. Reads only what it needs and
    /// never mutates.
    static func snapshot(context: ModelContext, windowDays: Int = 30,
                         now: Date = Date()) -> ProductMetricsSnapshot {
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: now) ?? .distantPast
        let events = ((try? context.fetch(FetchDescriptor<AppEvent>())) ?? [])
            .filter { $0.date >= cutoff }
        let calls: [ToolCallRecord] = events.compactMap { e in
            guard e.kind == .toolCall else { return nil }
            // detail is "name(input…) → result…" — the name is up to the paren.
            let name = e.detail.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
            return ToolCallRecord(date: e.date, toolName: String(name), subject: e.subjectID)
        }
        let generations: [GenerationRecord] = ((try? context.fetch(FetchDescriptor<PlanGenerationLog>())) ?? [])
            .filter { $0.startedAt >= cutoff }
            .map { GenerationRecord(startedAt: $0.startedAt,
                                    succeeded: $0.outcome == .success || $0.outcome == .repaired,
                                    isUserRequested: $0.trigger != .autoPlan) }
        let turns: [SessionTurn] = ((try? context.fetch(FetchDescriptor<ChatTurn>())) ?? [])
            .filter { $0.timestamp >= cutoff }
            .map { SessionTurn(date: $0.timestamp, isUser: $0.roleRaw == "user") }

        return ProductMetricsSnapshot(
            windowDays: windowDays,
            correctionRate: correctionRate(calls),
            replanAcceptance: replanAcceptance(generations),
            timeToOutcomeMinutes: timeToOutcome(turns: turns, calls: calls))
    }
}
