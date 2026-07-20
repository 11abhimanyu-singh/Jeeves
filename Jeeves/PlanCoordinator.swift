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

enum PlanCoordinator {
    struct Inputs {
        var userMessage: String = ""
        var hasGym: Bool
        var gymMinute: Int?
        var events: [DailyEvent]
        var locations: [SavedLocation]
        var prepSessions: [PrepSession]
    }

    struct Result {
        let plan: GeneratedPlan
        let isOffline: Bool
        let error: String?
    }

    /// Generates a plan, preferring Claude and falling back to the deterministic
    /// engine if the API is unreachable or errors. The Claude plan is validated
    /// against the scheduler's rules; a plan with a SEVERE violation (dropped
    /// Must-do, wasted afternoon, overlap, out-of-bounds work) is retried once
    /// with the problems fed back, and the cleaner of the two is kept.
    static func generate(_ inputs: Inputs) async -> Result {
        let request = await buildRequest(inputs)

        guard let first = try? await PlanGenerationService.generate(request) else {
            return Result(plan: deterministic(inputs), isOffline: true, error: "planning service unreachable")
        }
        let firstViolations = PlanValidation.severe(first, request: request)
        if firstViolations.isEmpty {
            return Result(plan: first, isOffline: false, error: nil)
        }

        // One repair pass: tell the model exactly what was wrong.
        let repairRequest = requestWithCorrections(request, violations: firstViolations)
        guard let repaired = try? await PlanGenerationService.generate(repairRequest) else {
            return Result(plan: first, isOffline: false, error: nil) // keep the first plan if the retry can't run
        }
        let repairedViolations = PlanValidation.severe(repaired, request: request)
        let best = repairedViolations.count <= firstViolations.count ? repaired : first
        return Result(plan: best, isOffline: false, error: nil)
    }

    private static func requestWithCorrections(_ req: PlanRequest, violations: [PlanValidation.Violation]) -> PlanRequest {
        var r = req
        let list = violations.map { "- \($0.message)" }.joined(separator: "\n")
        let prefix = req.userMessage.isEmpty ? "" : req.userMessage + "\n\n"
        r.userMessage = prefix + "IMPORTANT: your previous plan for this day broke these rules. Produce a corrected plan that fixes ALL of them:\n\(list)"
        return r
    }

    // MARK: Request assembly (live Maps commute legs)

    private static func buildRequest(_ i: Inputs) async -> PlanRequest {
        var legs: [(label: String, from: String, to: String)] = []
        let homeAddr = i.locations.first { $0.kind == .home }?.address ?? ""
        let gymAddr = i.locations.first { $0.kind == .gym }?.address ?? ""
        if i.hasGym, !homeAddr.isEmpty, !gymAddr.isEmpty {
            legs.append(("Home→Gym", homeAddr, gymAddr))
            legs.append(("Gym→Home", gymAddr, homeAddr))
        }
        for e in i.events where !e.destinationAddress.isEmpty {
            let fromAddr = i.locations.first { $0.kind == e.outboundStart }?.address ?? homeAddr
            if !fromAddr.isEmpty {
                legs.append(("\(e.outboundStart.rawValue)→\(e.title)", fromAddr, e.destinationAddress))
            }
            if !homeAddr.isEmpty {
                legs.append(("\(e.title)→Home", e.destinationAddress, homeAddr))
            }
        }
        let commutes = await GoogleMapsService.commuteEstimates(legs: legs)

        return PlanRequest(
            userMessage: i.userMessage,
            hasGymToday: i.hasGym,
            gymMinute: i.gymMinute,
            events: i.events.sorted { $0.startMinute < $1.startMinute },
            locations: i.locations,
            defaultCommuteMinutes: 30,
            commuteEstimates: commutes,
            prepNeglectNote: prepNeglectNote(i.prepSessions)
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
