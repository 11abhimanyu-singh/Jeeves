//
//  PlanEval.swift
//  JeevesTests
//
//  Plan-quality eval with ChatGPT (gpt-5-mini) as an INDEPENDENT judge. For each
//  scenario it generates a plan via the real guardrailed coordinator (validator
//  + repair retry + fallback), then has OpenAI score it 0–1 against the rules,
//  and prints a report. The clock is PINNED (07:00) so scores don't drift with
//  when the test runs. Opt-in, gated on BOTH keys; skipped otherwise.
//
//  Run:
//    xcodebuild test -scheme Jeeves -destination '…' -only-testing:JeevesTests/PlanEval
//

import XCTest
@testable import Jeeves

final class PlanEval: XCTestCase {

    private struct Scenario {
        let name: String
        let userMessage: String
        let hasGym: Bool
        let gym: Int?
        let events: [DailyEvent]
        let now: Date          // pinned reference clock
        let showSchedule: Bool // print the full timeline (for the travel days)
    }

    private func at(_ h: Int, _ day: Date) -> Date {
        Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: day) ?? day
    }
    private func ymd(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!.startOfDay
    }
    private func event(_ day: Date, _ start: Int, _ end: Int, _ title: String) -> DailyEvent {
        DailyEvent(date: day, title: title, startMinute: start, endMinute: end,
                   destinationAddress: "MLR Convention Centre, Bengaluru", outboundStart: .home, source: .manual)
    }

    private var scenarios: [Scenario] {
        let today = Date().startOfDay
        let morning = at(7, today)
        let jul21 = ymd(2026, 7, 21)
        let jul22 = ymd(2026, 7, 22)
        return [
            Scenario(name: "Normal rest day", userMessage: "", hasGym: false, gym: nil, events: [], now: morning, showSchedule: false),
            Scenario(name: "Morning gym (11:00)", userMessage: "", hasGym: true, gym: 11 * 60, events: [], now: morning, showSchedule: false),
            Scenario(name: "Evening gym (17:00)", userMessage: "", hasGym: true, gym: 17 * 60, events: [], now: morning, showSchedule: false),
            Scenario(name: "Midday event + gym", userMessage: "", hasGym: true, gym: 11 * 60,
                     events: [event(today, 14 * 60, 15 * 60, "Dr Sree Lakshmi")], now: morning, showSchedule: false),
            Scenario(name: "Evening event", userMessage: "", hasGym: false, gym: nil,
                     events: [event(today, 19 * 60, 21 * 60, "Baithak live")], now: morning, showSchedule: false),

            // Overnight travel 21 Jul 16:00 → 22 Jul 12:30, modeled as two single-day anchors.
            Scenario(name: "21 Jul — leaving on overnight travel at 4pm",
                     userMessage: "I leave on overnight travel at 4:00 PM and am gone for the rest of the day.",
                     hasGym: false, gym: nil,
                     events: [event(jul21, 16 * 60, 20 * 60 + 30, "Travel (departing)")],
                     now: at(7, jul21), showSchedule: true),
            Scenario(name: "22 Jul — returning from travel at 12:30pm",
                     userMessage: "I'm returning from overnight travel and am only free from 12:30 PM onward; the morning is travel.",
                     hasGym: false, gym: nil,
                     events: [event(jul22, 8 * 60, 12 * 60 + 30, "Travel (returning)")],
                     now: at(7, jul22), showSchedule: true),
        ]
    }

    func testPlanQualityWithChatGPTJudge() async throws {
        try XCTSkipUnless(KeychainService.hasAPIKey, "no Anthropic key (needed to generate plans)")
        try XCTSkipUnless(KeychainService.hasOpenAIAPIKey, "no OpenAI key (needed for the ChatGPT judge)")

        var overalls: [Double] = []
        print("\n=========== PLAN EVAL (judge: \(OpenAIJudgeService.model), clock pinned 07:00) ===========")

        for s in scenarios {
            let result = await PlanCoordinator.generate(.init(
                userMessage: s.userMessage, hasGym: s.hasGym, gymMinute: s.gym,
                events: s.events, locations: [], prepSessions: [], referenceNow: s.now))
            let plan = result.plan
            let request = PlanRequest(userMessage: s.userMessage, hasGymToday: s.hasGym, gymMinute: s.gym,
                                      events: s.events, locations: [], defaultCommuteMinutes: 30,
                                      commuteEstimates: [:], prepNeglectNote: nil, referenceNow: s.now)
            let severe = PlanValidation.severe(plan, request: request)
            let verdict = try await OpenAIJudgeService.judge(plan: plan, scenario: "\(s.name). \(s.userMessage)")
            overalls.append(verdict.overall)

            print(String(format: "\n• %@  →  overall %.2f", s.name, verdict.overall))
            print(String(format: "   priorities %.2f | fullDay %.2f | chaining %.2f | coherence %.2f",
                         verdict.priorities, verdict.fullDay, verdict.chaining, verdict.coherence))
            print("   structural: \(severe.isEmpty ? "clean" : severe.map(\.message).joined(separator: "; "))")
            print("   judge: \(verdict.reasoning)")
            if s.showSchedule {
                print("   --- schedule ---")
                for blk in plan.blocks { print("     \(blk.startTime)–\(blk.endTime)  \(blk.title) [\(blk.kind)]") }
                if !plan.dropped.isEmpty { print("     dropped: \(plan.dropped.joined(separator: ", "))") }
            }
        }

        let mean = overalls.isEmpty ? 0 : overalls.reduce(0, +) / Double(overalls.count)
        print(String(format: "\n=========== MEAN OVERALL: %.2f over %d scenarios ===========\n", mean, overalls.count))
        XCTAssertGreaterThanOrEqual(mean, 0.6, "mean plan quality \(mean) below 0.6")
    }
}
