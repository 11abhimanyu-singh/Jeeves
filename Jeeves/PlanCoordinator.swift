//
//  PlanCoordinator.swift
//  Jeeves
//
//  One place that turns a day's inputs (gym, events, locations, prep history)
//  into a plan — via Claude (PlanGenerationService) with a deterministic
//  offline fallback (DayPlanner). Both the Jeeves chat and the Day Planner tab
//  call this, so "Plan my day" behaves identically wherever it's triggered and
//  the result can be persisted to DailyPlanState.
//

import Foundation
import SwiftData

enum PlanCoordinator {
    struct Inputs {
        var userMessage: String = ""
        var hasGym: Bool
        var gymMinute: Int?
        var events: [DailyEvent]
        var locations: [SavedLocation]
        var prepSessions: [PrepSession]
        var routine: [BaselineActivity] = Baseline.activities  // the user's editable routine
        var planDate: Date = Date()     // the day being planned — commute legs use its scheduled departure times for predictive traffic
        var referenceNow: Date? = nil   // pinned "now" for evals; nil = real clock
    }

    struct Result {
        let plan: GeneratedPlan
        let isOffline: Bool
        let error: String?
        var retryCount: Int = 0   // 1 when a repair round-trip was made
        var commuteMs: Int = 0    // time spent fetching commute times (Maps)
        var claudeMs: Int = 0     // time spent in the Claude call(s)
    }

    /// Same as `generate`, but records a diagnostics log (duration + outcome,
    /// with a pending record up front so a generation that never returns is
    /// still captured). Views use this; tests/eval call `generate` directly.
    static func generateLogged(_ inputs: Inputs, context: ModelContext, trigger: PlanGenTrigger) async -> Result {
        let started = Date()
        let log = PlanDiagnostics.begin(trigger: trigger, context: context)
        let result = await generate(inputs)
        PlanDiagnostics.finish(log, isOffline: result.isOffline, retryCount: result.retryCount,
                               commuteMs: result.commuteMs, claudeMs: result.claudeMs,
                               errorClass: result.error, startedAt: started, context: context)
        // Mirror the updated diagnostics to iCloud Drive for hands-free reading.
        let allLogs = (try? context.fetch(FetchDescriptor<PlanGenerationLog>())) ?? []
        DiagnosticsSync.write(DiagnosticsSync.entries(from: allLogs))
        return result
    }

    /// Generates a plan, preferring Claude and falling back to the deterministic
    /// engine if the API is unreachable or errors. The Claude plan is validated
    /// against the scheduler's rules; a plan with a SEVERE violation (dropped
    /// Must-do, wasted afternoon, overlap, out-of-bounds work) is retried once
    /// with the problems fed back, and the cleaner of the two is kept.
    static func generate(_ inputs: Inputs) async -> Result {
        let t0 = Date()
        let request = await buildRequest(inputs)   // Maps commute lookups happen here
        let commuteMs = Int(Date().timeIntervalSince(t0) * 1000)

        let tClaude = Date()
        guard let first = try? await PlanGenerationService.generate(request) else {
            return Result(plan: deterministic(inputs), isOffline: true, error: "planning service unreachable",
                          commuteMs: commuteMs, claudeMs: Int(Date().timeIntervalSince(tClaude) * 1000))
        }
        let firstViolations = PlanValidation.severe(first, request: request)
        if firstViolations.isEmpty {
            return Result(plan: first, isOffline: false, error: nil,
                          commuteMs: commuteMs, claudeMs: Int(Date().timeIntervalSince(tClaude) * 1000))
        }

        // One repair pass: tell the model exactly what was wrong.
        let repairRequest = requestWithCorrections(request, violations: firstViolations)
        guard let repaired = try? await PlanGenerationService.generate(repairRequest) else {
            return Result(plan: first, isOffline: false, error: nil, // keep the first plan if the retry can't run
                          commuteMs: commuteMs, claudeMs: Int(Date().timeIntervalSince(tClaude) * 1000))
        }
        let repairedViolations = PlanValidation.severe(repaired, request: request)
        let best = repairedViolations.count <= firstViolations.count ? repaired : first
        return Result(plan: best, isOffline: false, error: nil, retryCount: 1,
                      commuteMs: commuteMs, claudeMs: Int(Date().timeIntervalSince(tClaude) * 1000))
    }

    private static func requestWithCorrections(_ req: PlanRequest, violations: [PlanValidation.Violation]) -> PlanRequest {
        var r = req
        let list = violations.map { "- \($0.message)" }.joined(separator: "\n")
        let prefix = req.userMessage.isEmpty ? "" : req.userMessage + "\n\n"
        r.userMessage = prefix + "IMPORTANT: your previous plan for this day broke these rules. Produce a corrected plan that fixes ALL of them:\n\(list)"
        return r
    }

    // MARK: Request assembly (live Maps commute legs)

    /// When each commute leg actually departs, as minutes-since-midnight on the
    /// plan date, derived from the anchors. Feeding these to the Routes API
    /// gets PREDICTED traffic for that time of day instead of traffic at the
    /// moment the plan is generated (planning at night for a midday leg would
    /// otherwise price in empty roads). Pure and unit-tested.
    ///
    /// Event legs are checked FIRST, with the exact label shapes buildRequest
    /// constructs — so a calendar event literally titled "Gym" (a common
    /// calendar entry) is priced by ITS times, not mistaken for the gym-anchor
    /// commute.
    static func legDepartureMinute(label: String, gymMinute: Int?, events: [DailyEvent]) -> Int? {
        for e in events {
            if label == "\(e.title)→Home" { return e.endMinute }
            for kind in LocationKind.allCases where label == "\(kind.rawValue)→\(e.title)" {
                return e.startMinute - 45   // leave ~45 min before the event
            }
        }
        if label == "Home→Gym", let g = gymMinute {
            return g - 50   // 30 commute + 20 mobility before the weights start
        }
        if label == "Gym→Home", let g = gymMinute {
            return g + 70 + 35   // weights + cardio, then drive home
        }
        return nil
    }

    /// A concrete Date on `day` at wall-clock `minuteOfDay` (bySettingHour, so
    /// a 13:30 leg means 13:30 local even across a DST transition — elapsed-
    /// minute arithmetic would drift an hour on changeover days).
    static func departureDate(minuteOfDay: Int, on day: Date) -> Date? {
        let m = max(0, minuteOfDay)
        return Calendar.current.date(bySettingHour: (m / 60) % 24, minute: m % 60, second: 0, of: day.startOfDay)
    }

    typealias CommuteLeg = (label: String, from: String, to: String, departure: Date?)

    /// The commute legs a day's anchors require, each with its scheduled
    /// departure on the plan date. Pure — split out of buildRequest so the
    /// wiring (labels ↔ departures) is unit-testable without network.
    static func commuteLegs(_ i: Inputs) -> [CommuteLeg] {
        var legs: [CommuteLeg] = []
        let homeAddr = i.locations.first { $0.kind == .home }?.address ?? ""
        let gymAddr = i.locations.first { $0.kind == .gym }?.address ?? ""
        func departure(for label: String) -> Date? {
            guard let minute = legDepartureMinute(label: label, gymMinute: i.hasGym ? i.gymMinute : nil, events: i.events) else { return nil }
            return departureDate(minuteOfDay: minute, on: i.planDate)
        }
        if i.hasGym, !homeAddr.isEmpty, !gymAddr.isEmpty {
            legs.append(("Home→Gym", homeAddr, gymAddr, departure(for: "Home→Gym")))
            legs.append(("Gym→Home", gymAddr, homeAddr, departure(for: "Gym→Home")))
        }
        for e in i.events where !e.destinationAddress.isEmpty {
            let fromAddr = i.locations.first { $0.kind == e.outboundStart }?.address ?? homeAddr
            if !fromAddr.isEmpty {
                let label = "\(e.outboundStart.rawValue)→\(e.title)"
                legs.append((label, fromAddr, e.destinationAddress, departure(for: label)))
            }
            if !homeAddr.isEmpty {
                let label = "\(e.title)→Home"
                legs.append((label, e.destinationAddress, homeAddr, departure(for: label)))
            }
        }
        return legs
    }

    private static func buildRequest(_ i: Inputs) async -> PlanRequest {
        let commutes = await GoogleMapsService.commuteEstimates(legs: commuteLegs(i))

        return PlanRequest(
            userMessage: i.userMessage,
            hasGymToday: i.hasGym,
            gymMinute: i.gymMinute,
            events: i.events.sorted { $0.startMinute < $1.startMinute },
            locations: i.locations,
            defaultCommuteMinutes: 30,
            commuteEstimates: commutes,
            prepNeglectNote: prepNeglectNote(i.prepSessions),
            routine: i.routine,
            referenceNow: i.referenceNow
        )
    }

    // MARK: Deterministic offline fallback

    private static func deterministic(_ i: Inputs) -> GeneratedPlan {
        let blocks = DayPlanner.generate(
            gymMinute: i.hasGym ? i.gymMinute : nil,
            prepSessions: i.prepSessions,
            leisureLogs: []
        )
        let generated = blocks.map { b in
            GeneratedBlock(
                title: b.title,
                startTime: String(format: "%02d:%02d", b.startMinute / 60, b.startMinute % 60),
                endTime: String(format: "%02d:%02d", b.endMinute / 60, b.endMinute % 60),
                note: b.note,
                isAnchor: b.isAnchor,
                kind: b.isAnchor ? "anchor" : "activity"
            )
        }
        return GeneratedPlan(
            blocks: generated, dropped: [], shrunk: [],
            summary: "Offline plan from the built-in scheduler.", boundaryTime: nil
        )
    }

    static func prepNeglectNote(_ prepSessions: [PrepSession]) -> String? {
        let categories: [PrepCategory] = [.productSense, .execution, .strategy, .behavioral]
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let recent = prepSessions.filter { $0.date >= weekAgo && $0.category != .reading }
        let counts = Dictionary(grouping: recent, by: { $0.category }).mapValues(\.count)
        let ranked = categories.sorted { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
        return "Fewest practice sessions this week (most neglected first): " + ranked.map(\.rawValue).joined(separator: ", ")
    }
}
