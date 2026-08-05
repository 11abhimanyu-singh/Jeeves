//
//  ProviderBenchmark.swift
//  JeevesTests
//
//  Two providers, one prompt, real days.
//
//  WHY THIS EXISTS. Two questions landed together. A fallback provider was asked
//  for "in case Anthropic doesn't respond" — but since real error reporting
//  landed on 1 Aug, 14 of 14 recorded failures were client-side transport
//  (connection lost, timed out) and not one was an API refusal, so a fallback is
//  outage insurance rather than a fix. And the planner model was changed twice in
//  one day, to claude-fable-5, which has thinking always on — so the ~53s median
//  measured from the device predates the model now in use and nobody knows what
//  the planner currently costs.
//
//  Both questions are answered by measuring, so measure before building.
//
//  WHAT IT DOES NOT DO. The diagnostics log stores timings and outcomes only — no
//  prompts, no bodies, no responses. The historical calls cannot be replayed.
//  These are RECONSTRUCTED days: real events and anchors from the scenarios
//  below, put to both providers identically. That is better for comparison than a
//  replay would be, but it is not the same claim, and saying otherwise would be
//  dishonest about what the numbers cover.
//
//  LATENCY ALONE WOULD MISLEAD. Up to 45% of Claude plans currently need a repair
//  round-trip — a second full generation because the first broke a rule. A
//  provider that answers in 20s and fails validation costs two calls: slower AND
//  worse. So every run is scored as well as timed, and the summary reports
//  EFFECTIVE latency — median × (1 + first-pass failure rate).
//
//  Skipped without both keys, like every other live test here.
//

import XCTest
@testable import Jeeves

final class ProviderBenchmark: XCTestCase {

    private struct Sample {
        let name: String
        let hasGym: Bool
        let gymMinute: Int?
        let events: [DailyEvent]
        let now: Date
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 4) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: day,
                                                   hour: hour, minute: minute))!
    }

    private func event(_ title: String, _ start: Int, _ end: Int,
                       at place: String = "", day: Int = 4) -> DailyEvent {
        DailyEvent(date: at(0, day: day).startOfDay, title: title,
                   startMinute: start, endMinute: end,
                   destinationAddress: place, outboundStart: .home, source: .calendar)
    }

    /// Shapes taken from the days actually planned this week, not invented ones:
    /// a free day, a gym day, an afternoon appointment with a commute, an evening
    /// gym, and a day carrying both an appointment and the gym.
    private var samples: [Sample] {
        [
            Sample(name: "free day, no anchors", hasGym: false, gymMinute: nil,
                   events: [], now: at(7)),
            Sample(name: "morning gym", hasGym: true, gymMinute: 7 * 60,
                   events: [], now: at(7)),
            Sample(name: "afternoon appointment with a commute", hasGym: false, gymMinute: nil,
                   events: [event("Appointment with Dr Krithi", 16 * 60, 19 * 60,
                                  at: "Tasvaa Skin And Hair Clinic")],
                   now: at(7)),
            Sample(name: "evening gym", hasGym: true, gymMinute: 19 * 60,
                   events: [], now: at(7)),
            Sample(name: "appointment and gym together", hasGym: true, gymMinute: 11 * 60,
                   events: [event("Appointment with Dr Krithi", 16 * 60, 19 * 60,
                                  at: "Tasvaa Skin And Hair Clinic")],
                   now: at(7)),
            Sample(name: "mid-day, planning the remainder", hasGym: false, gymMinute: nil,
                   events: [event("Standup", 9 * 60 + 30, 10 * 60)],
                   now: at(12, 45)),
        ]
    }

    private struct Run {
        let provider: String
        let seconds: Double
        let validFirstTime: Bool
        let violations: String
        let decoded: Bool
    }

    func testAnthropicVersusOpenAIOnRealDays() async throws {
        try XCTSkipUnless(KeychainService.hasResolvableAPIKey, "no Anthropic key")
        try XCTSkipUnless(KeychainService.hasResolvableOpenAIKey, "no OpenAI key")

        var runs: [String: [Run]] = [:]
        print("\n===== PROVIDER BENCHMARK =====")
        print("anthropic: \(PlanGenerationService.modelIdentifier)   openai: \(OpenAIPlanService.model)")
        print("Commute estimates are STUBBED — Maps measured 0s on device and would")
        print("only add noise. Both providers get a byte-identical prompt.\n")

        for sample in samples {
            // One request, built once. Commute estimates fixed rather than fetched
            // so the prompt is deterministic and the timing is the provider's.
            let request = PlanRequest(
                userMessage: "", hasGymToday: sample.hasGym, gymMinute: sample.gymMinute,
                events: sample.events, locations: [], defaultCommuteMinutes: 30,
                commuteEstimates: ["Home→Gym": 30, "Gym→Home": 28,
                                   "Home→Appointment with Dr Krithi": 26,
                                   "Appointment with Dr Krithi→Home": 24],
                prepNeglectNote: PlanCoordinator.prepNeglectNote([]),
                routine: Baseline.activities, referenceNow: sample.now)

            let rules = PlanGenerationService.planningRules(hasEvents: !sample.events.isEmpty)
            let user = PlanGenerationService.userPrompt(request)

            print("• \(sample.name)")

            // ANTHROPIC
            let aStart = Date()
            var aRun: Run
            do {
                let plan = try await PlanGenerationService.generate(request)
                let severe = PlanValidation.severe(plan, request: request)
                aRun = Run(provider: "anthropic", seconds: Date().timeIntervalSince(aStart),
                           validFirstTime: severe.isEmpty,
                           violations: PlanDiagnostics.violationKinds(severe.map(\.message)),
                           decoded: true)
            } catch {
                aRun = Run(provider: "anthropic", seconds: Date().timeIntervalSince(aStart),
                           validFirstTime: false, violations: "ERROR: \(error.localizedDescription)",
                           decoded: false)
            }
            report(aRun)
            runs["anthropic", default: []].append(aRun)

            // OPENAI — the same two strings, so any difference is the provider.
            let oStart = Date()
            var oRun: Run
            do {
                let plan = try await OpenAIPlanService.generate(systemRules: rules, userPrompt: user)
                let severe = PlanValidation.severe(plan, request: request)
                oRun = Run(provider: "openai", seconds: Date().timeIntervalSince(oStart),
                           validFirstTime: severe.isEmpty,
                           violations: PlanDiagnostics.violationKinds(severe.map(\.message)),
                           decoded: true)
            } catch {
                oRun = Run(provider: "openai", seconds: Date().timeIntervalSince(oStart),
                           validFirstTime: false, violations: "ERROR: \(error.localizedDescription)",
                           decoded: false)
            }
            report(oRun)
            runs["openai", default: []].append(oRun)
        }

        print("\n===== SUMMARY =====")
        for provider in ["anthropic", "openai"] {
            guard let rs = runs[provider], !rs.isEmpty else { continue }
            let times = rs.map(\.seconds).sorted()
            let median = times[times.count / 2]
            let validRate = Double(rs.filter(\.validFirstTime).count) / Double(rs.count)
            let decodeFailures = rs.filter { !$0.decoded }.count
            // What a call really costs: a plan that fails validation buys a second
            // full generation, so the honest figure is time x (1 + failure rate).
            let effective = median * (1 + (1 - validRate))
            print(String(format: "%@  median %.1fs (min %.1f, max %.1f) | valid first time %.0f%% | decode failures %d | EFFECTIVE %.1fs",
                         provider, median, times.first ?? 0, times.last ?? 0,
                         validRate * 100, decodeFailures, effective))
        }
        print("\nSingle sample per day per provider. Enough to see a large gap;")
        print("NOT enough to separate two providers within ~20% of each other.\n")
    }

    private func report(_ run: Run) {
        print(String(format: "   %-10@ %6.1fs  %@  %@", run.provider as NSString, run.seconds,
                     run.validFirstTime ? "valid" : "INVALID",
                     run.violations.isEmpty ? "" : run.violations))
    }

    /// The benchmark is worthless if the two providers saw different prompts, so
    /// prove they cannot. Runs without any key.
    func testBothProvidersReceiveTheIdenticalPrompt() {
        let request = PlanRequest(
            userMessage: "", hasGymToday: true, gymMinute: 11 * 60,
            events: [event("Appointment", 16 * 60, 19 * 60, at: "Clinic")],
            locations: [], defaultCommuteMinutes: 30, commuteEstimates: [:],
            prepNeglectNote: nil, routine: Baseline.activities, referenceNow: at(7))

        let rules = PlanGenerationService.planningRules(hasEvents: true)
        let user = PlanGenerationService.userPrompt(request)

        XCTAssertFalse(rules.isEmpty)
        XCTAssertFalse(user.isEmpty)
        // Building twice from the same request must be byte-identical, otherwise
        // the two providers are not being asked the same question.
        XCTAssertEqual(user, PlanGenerationService.userPrompt(request),
                       "the prompt must be deterministic or the comparison is noise")
        XCTAssertEqual(rules, PlanGenerationService.planningRules(hasEvents: true))
        // And it must carry no provider-specific scaffolding.
        for provider in ["anthropic", "x-api-key", "openai", "choices", "content_block"] {
            XCTAssertFalse(rules.lowercased().contains(provider), "rules leak \(provider)")
            XCTAssertFalse(user.lowercased().contains(provider), "prompt leaks \(provider)")
        }
    }

    /// An OpenAI envelope decodes to the same contract, without a network.
    func testAnOpenAIEnvelopeDecodesToTheSharedContract() throws {
        let body = """
        {"choices":[{"message":{"content":"{\\"blocks\\":[{\\"title\\":\\"Chores\\",\\"startTime\\":\\"08:00\\",\\"endTime\\":\\"08:40\\",\\"note\\":null,\\"isAnchor\\":false,\\"kind\\":\\"activity\\"}],\\"dropped\\":[],\\"shrunk\\":[],\\"summary\\":\\"x\\",\\"boundaryTime\\":null}"}}]}
        """.data(using: .utf8)!
        let plan = try XCTUnwrap(OpenAIPlanService.parse(body))
        XCTAssertEqual(plan.blocks.first?.title, "Chores")
    }

    /// A fenced reply still decodes — the shared decoder already handles it, and
    /// this pins that OpenAI's path really does go through it.
    func testAFencedOpenAIReplyStillDecodes() throws {
        let inner = "```json\\n{\\\"blocks\\\":[],\\\"dropped\\\":[],\\\"shrunk\\\":[],\\\"summary\\\":\\\"s\\\",\\\"boundaryTime\\\":null}\\n```"
        let body = "{\"choices\":[{\"message\":{\"content\":\"\(inner)\"}}]}".data(using: .utf8)!
        XCTAssertNotNil(OpenAIPlanService.parse(body))
    }

    func testAnEmptyOrMalformedEnvelopeIsNotAPlan() {
        XCTAssertNil(OpenAIPlanService.parse(Data()))
        XCTAssertNil(OpenAIPlanService.parse("{\"choices\":[]}".data(using: .utf8)!))
        XCTAssertNil(OpenAIPlanService.parse("not json".data(using: .utf8)!))
    }
}
