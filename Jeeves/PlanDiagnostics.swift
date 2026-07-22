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

enum PlanGenTrigger: String, Codable { case planner, chat }

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
    var triggerRaw: String = PlanGenTrigger.planner.rawValue
    var outcomeRaw: String = PlanGenOutcome.pending.rawValue
    var retryCount: Int = 0
    var errorClass: String? = nil

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
        try? context.save()
        return log
    }

    /// Resolve the pending record once generation returns.
    static func finish(_ log: PlanGenerationLog, isOffline: Bool, retryCount: Int, errorClass: String?, startedAt: Date, context: ModelContext) {
        log.durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        log.outcome = outcome(isOffline: isOffline, retryCount: retryCount)
        log.retryCount = retryCount
        log.errorClass = errorClass
        try? context.save()
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
        if !stale.isEmpty { try? context.save() }
    }

    struct Summary {
        var total = 0
        var succeeded = 0    // success + repaired
        var offline = 0
        var abandoned = 0
        var p50Ms = 0
        var p95Ms = 0
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
        let durations = finished.filter { $0.outcome != .abandoned }.map(\.durationMs).sorted()
        if !durations.isEmpty {
            s.p50Ms = durations[durations.count / 2]
            s.p95Ms = durations[min(durations.count - 1, Int(Double(durations.count) * 0.95))]
        }
        return s
    }
}
