//
//  PlanEval.swift
//  JeevesTests
//
//  Plan-quality eval with ChatGPT as an INDEPENDENT judge. For each scenario it
//  generates a plan with Claude, then has OpenAI score it 0–1 against the
//  scheduler's rules, and prints a report. Opt-in and gated on BOTH keys
//  (Anthropic to generate, OpenAI to judge) — skipped otherwise, no impact on
//  the fast suite. Also runs the free structural validator on every plan.
//
//  Run:
//    xcodebuild test -scheme Jeeves -destination '…' -only-testing:JeevesTests/PlanEval
//

import XCTest
@testable import Jeeves

final class PlanEval: XCTestCase {

    private struct Scenario {
        let name: String
        let request: PlanRequest
    }

    private func event(_ start: Int, _ end: Int, _ title: String) -> DailyEvent {
        DailyEvent(date: Date().startOfDay, title: title, startMinute: start, endMinute: end,
                   destinationAddress: "MLR Convention Centre, Bengaluru", outboundStart: .home, source: .manual)
    }

    private func req(_ hasGym: Bool, _ gym: Int?, _ events: [DailyEvent]) -> PlanRequest {
        PlanRequest(userMessage: "", hasGymToday: hasGym, gymMinute: gym, events: events,
                    locations: [], defaultCommuteMinutes: 30, commuteEstimates: [:], prepNeglectNote: nil)
    }

    private var scenarios: [Scenario] {
        [
            Scenario(name: "Normal rest day", request: req(false, nil, [])),
            Scenario(name: "Morning gym (11:00)", request: req(true, 11 * 60, [])),
            Scenario(name: "Evening gym (17:00)", request: req(true, 17 * 60, [])),
            Scenario(name: "Midday event + gym", request: req(true, 11 * 60, [event(14 * 60, 15 * 60, "Dr Sree Lakshmi")])),
            Scenario(name: "Evening event", request: req(false, nil, [event(19 * 60, 21 * 60, "Baithak live")])),
        ]
    }

    func testPlanQualityWithChatGPTJudge() async throws {
        try XCTSkipUnless(KeychainService.hasAPIKey, "no Anthropic key (needed to generate plans)")
        try XCTSkipUnless(KeychainService.hasOpenAIAPIKey, "no OpenAI key (needed for the ChatGPT judge)")

        var overalls: [Double] = []
        print("\n=========== PLAN EVAL (judge: \(OpenAIJudgeService.model)) ===========")

        for s in scenarios {
            guard let plan = try? await PlanGenerationService.generate(s.request) else {
                print("[\(s.name)] generation FAILED"); continue
            }
            // Free structural check first.
            let severe = PlanValidation.severe(plan, request: s.request)
            // Independent quality judge.
            let verdict = try await OpenAIJudgeService.judge(plan: plan, scenario: s.name)
            overalls.append(verdict.overall)

            print(String(format: "\n• %@  →  overall %.2f", s.name, verdict.overall))
            print(String(format: "   priorities %.2f | fullDay %.2f | chaining %.2f | coherence %.2f",
                         verdict.priorities, verdict.fullDay, verdict.chaining, verdict.coherence))
            print("   structural violations: \(severe.isEmpty ? "none" : severe.map(\.message).joined(separator: "; "))")
            print("   judge: \(verdict.reasoning)")
        }

        let mean = overalls.isEmpty ? 0 : overalls.reduce(0, +) / Double(overalls.count)
        print(String(format: "\n=========== MEAN OVERALL: %.2f over %d scenarios ===========\n", mean, overalls.count))

        // Soft gate — flags a real quality regression without being flaky.
        XCTAssertGreaterThanOrEqual(mean, 0.6, "mean plan quality \(mean) below 0.6")
    }
}
