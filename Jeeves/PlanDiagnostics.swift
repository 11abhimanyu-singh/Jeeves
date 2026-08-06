//
//  PlanDiagnostics.swift
//  Jeeves
//
//  Answers two questions about the planner: how long does Jeeves take to
//  return a plan, and does it actually return at all? Each generation writes a
//  "pending" record the instant it starts and updates it on completion — so a
//  record still pending after the app is next launched means a generation that
//  never returned (a crash, a kill, or a hang), which no finish-only log could
//  catch. On-device SwiftData so it's visible untethered.
//

import Foundation
import SwiftData

enum PlanGenTrigger: String, Codable { case planner, chat, autoPlan }

enum PlanGenOutcome: String, Codable {
    case pending          // in flight (or never returned, if it stays this way)
    case success          // clean Claude plan, first try
    case repaired         // first plan had a severe violation; repaired retry kept
    case offlineFallback  // Claude unreachable; deterministic engine used
    case abandoned        // was pending, still pending on a later launch → never returned
}

@Model
final class PlanGenerationLog {
    var startedAt: Date = Date.distantPast
    var durationMs: Int = 0
    var commuteMs: Int = 0    // sub-span: time fetching commute times (Maps)
    var claudeMs: Int = 0     // sub-span: time in the Claude call(s)
    var triggerRaw: String = PlanGenTrigger.planner.rawValue
    var outcomeRaw: String = PlanGenOutcome.pending.rawValue
    var retryCount: Int = 0
    var errorClass: String?
    /// Which RULES the first plan broke, when a repair round-trip was made.
    ///
    /// Up to 45% of chat generations were doing two full ~53s calls because the
    /// first plan failed validation — the single largest slice of latency, and
    /// latency is upstream of every failure mode. Nothing recorded WHICH rule,
    /// so the repair rate was visible but not fixable.
    var violationClass: String? = nil

    var trigger: PlanGenTrigger { PlanGenTrigger(rawValue: triggerRaw) ?? .planner }
    var outcome: PlanGenOutcome {
        get { PlanGenOutcome(rawValue: outcomeRaw) ?? .pending }
        set { outcomeRaw = newValue.rawValue }
    }

    init(startedAt: Date, trigger: PlanGenTrigger) {
        self.startedAt = startedAt
        self.triggerRaw = trigger.rawValue
    }
}

enum PlanDiagnostics {
    /// Classify a coordinator result into an outcome (pure — unit-tested).
    static func outcome(isOffline: Bool, retryCount: Int) -> PlanGenOutcome {
        if isOffline { return .offlineFallback }
        return retryCount > 0 ? .repaired : .success
    }

    /// Persist a pending record before generation starts.
    static func begin(trigger: PlanGenTrigger, context: ModelContext) -> PlanGenerationLog {
        let log = PlanGenerationLog(startedAt: Date(), trigger: trigger)
        context.insert(log)
        context.saveOrLog()
        return log
    }

    /// Resolve the pending record once generation returns.
    static func finish(_ log: PlanGenerationLog, isOffline: Bool, retryCount: Int, commuteMs: Int, claudeMs: Int, errorClass: String?, startedAt: Date, context: ModelContext,
                       violations: [String] = []) {
        log.durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        log.commuteMs = commuteMs
        log.claudeMs = claudeMs
        log.outcome = outcome(isOffline: isOffline, retryCount: retryCount)
        log.retryCount = retryCount
        log.errorClass = errorClass
        log.violationClass = violations.isEmpty ? nil : Self.violationKinds(violations)
        context.saveOrLog()
    }

    /// Violation MESSAGES carry specifics ("'Lunch' starts 14:45, past the
    /// 14:30 deadline"); what's wanted for a tally is the KIND. Reduce each to
    /// a stable slug so a week of logs answers "which rule does the model break
    /// most" instead of producing 40 unique strings.
    static func violationKinds(_ messages: [String]) -> String {
        var kinds: [String] = []
        for m in messages {
            let t = m.lowercased()
            let kind: String
            // Matched against the messages the validator ACTUALLY emits (see
            // PlanValidation and PlanRules.prepBreatherViolations) — the first
            // draft of this guessed at wordings and classified the breather
            // rule, whose message never says "breather", as "other".
            if t.contains("overlap") { kind = "overlap" }
            else if t.contains("lunch") { kind = "lunch-window" }
            else if t.contains("between them") || t.contains("interview-prep blocks need") {
                kind = "prep-breather"
            }
            else if t.contains("must-do dropped") || t.contains("dropped") { kind = "dropped-must-do" }
            // Every gym rule opens with "Gym", so lead with that rather than with
            // the vocabulary of any one message. The earlier list spelled out
            // "weightlifting"/"gym routine"/"gym day", and when the length rule was
            // reworded from "Weightlifting is N min…" to "Gym is N min…" the most
            // common gym violation quietly started counting as "other" — the bucket
            // stayed alive on its two other members, so nothing looked broken.
            else if t.hasPrefix("gym") || t.contains("weightlifting") {
                kind = "gym-shape"
            }
            else if t.contains("measures") || t.contains("commute") { kind = "commute-length" }
            else if t.contains("event block") { kind = "event-count" }
            else if t.contains("work was dropped") || t.contains("nothing") { kind = "wasted-afternoon" }
            else if t.contains("boundary") || t.contains("20:30") { kind = "past-boundary" }
            else { kind = "other" }
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        return kinds.sorted().joined(separator: ",")
    }

    /// A generation still `pending` well after it started never returned — mark
    /// it abandoned so the record reflects reality. Run at launch.
    static func sweepAbandoned(context: ModelContext, olderThan seconds: TimeInterval = 300) {
        let cutoff = Date().addingTimeInterval(-seconds)
        let pendingRaw = PlanGenOutcome.pending.rawValue
        let descriptor = FetchDescriptor<PlanGenerationLog>(
            predicate: #Predicate { $0.outcomeRaw == pendingRaw && $0.startedAt < cutoff })
        let stale = (try? context.fetch(descriptor)) ?? []
        for log in stale { log.outcomeRaw = PlanGenOutcome.abandoned.rawValue }
        if !stale.isEmpty { context.saveOrLog() }
    }

    struct Summary {
        var total = 0
        var succeeded = 0    // success + repaired
        var offline = 0
        var abandoned = 0
        var p50Ms = 0
        var p95Ms = 0
        var p50CommuteMs = 0  // median of the Maps sub-span
        var p50ClaudeMs = 0   // median of the Claude sub-span
        var successRate: Double { total == 0 ? 0 : Double(succeeded) / Double(total) }
    }

    /// Aggregate a set of logs into headline numbers (pure — unit-tested).
    static func summarize(_ logs: [PlanGenerationLog]) -> Summary {
        var s = Summary()
        let finished = logs.filter { $0.outcome != .pending }
        s.total = finished.count
        s.succeeded = finished.filter { $0.outcome == .success || $0.outcome == .repaired }.count
        s.offline = finished.filter { $0.outcome == .offlineFallback }.count
        s.abandoned = finished.filter { $0.outcome == .abandoned }.count
        let real = finished.filter { $0.outcome != .abandoned }
        func median(_ values: [Int]) -> Int {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        func p95(_ values: [Int]) -> Int {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        s.p50Ms = median(real.map(\.durationMs))
        s.p95Ms = p95(real.map(\.durationMs))
        s.p50CommuteMs = median(real.map(\.commuteMs))
        s.p50ClaudeMs = median(real.map(\.claudeMs))
        return s
    }
}
