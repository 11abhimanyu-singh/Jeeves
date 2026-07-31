//
//  PromptCacheTests.swift
//  JeevesTests
//
//  Prompt caching fails silently. If a volatile byte creeps into the cached
//  block, or the block drops under the model's minimum, or a rule quietly
//  goes missing in the split — every call still succeeds. You just pay 1.25x
//  forever instead of 0.1x, and nothing ever says so.
//
//  These tests are the thing that says so.
//

import XCTest
@testable import Jeeves

final class PromptCacheTests: XCTestCase {

    private func request(events: [DailyEvent] = [], message: String = "") -> PlanRequest {
        PlanRequest(userMessage: message, hasGymToday: false, gymMinute: nil, events: events,
                    locations: [], defaultCommuteMinutes: 30, commuteEstimates: [:],
                    prepNeglectNote: nil)
    }

    private func event(_ start: Int, _ end: Int) -> DailyEvent {
        DailyEvent(date: Date().startOfDay, title: "Appt", startMinute: start, endMinute: end,
                   destinationAddress: "somewhere", outboundStart: .home, source: .manual)
    }

    // MARK: The cached block must be stable

    func testPlanningRulesAreByteIdenticalAcrossCalls() {
        // Cache hits require a 100% identical prefix. Two calls, same inputs,
        // must produce the same string down to the byte.
        XCTAssertEqual(PlanGenerationService.planningRules(hasEvents: false),
                       PlanGenerationService.planningRules(hasEvents: false))
        XCTAssertEqual(PlanGenerationService.planningRules(hasEvents: true),
                       PlanGenerationService.planningRules(hasEvents: true))
    }

    func testPlanningRulesCarryNoDateOrClock() {
        // The exact bug this guards: dateContext() used to sit in the middle of
        // the prompt. Anything carrying the current minute inside the cached
        // block changes the prefix on every call — hit rate zero, and the only
        // symptom is a bigger bill.
        for rules in [PlanGenerationService.planningRules(hasEvents: false),
                      PlanGenerationService.planningRules(hasEvents: true)] {
            XCTAssertFalse(rules.contains("current date and time"),
                           "dateContext leaked into the cacheable block")
            let year = Calendar.current.component(.year, from: Date())
            XCTAssertFalse(rules.contains(String(year)),
                           "a live year in the cached block breaks every cache hit")
        }
    }

    func testPlanningRulesClearTheModelMinimum() {
        // claude-opus-4-8 will not cache a prefix under 1,024 tokens, and it
        // does NOT error when it declines — it just quietly doesn't cache.
        // ~4 chars/token, so require comfortably over 4,096 characters.
        let rules = PlanGenerationService.planningRules(hasEvents: false)
        XCTAssertGreaterThan(rules.count, 5_000,
                             "cacheable block is near the 1,024-token floor — caching may silently no-op")
    }

    // MARK: The volatile block must stay out of the cache

    func testUserPromptCarriesTheDayNotTheRules() {
        let p = PlanGenerationService.userPrompt(request(message: "busy day"))
        XCTAssertTrue(p.contains("current date and time"), "the day's clock belongs in the volatile half")
        XCTAssertTrue(p.contains("busy day"))
        XCTAssertFalse(p.contains("PRIORITY RULES"), "static rules must not sit in the volatile half")
        XCTAssertFalse(p.contains("RESPOND WITH STRICT JSON"), "the contract is static — it belongs in the cached half")
    }

    // MARK: Nothing lost in the move

    func testEveryRuleSectionSurvivesTheSplit() {
        // The split moved text between two prompts. Together they must still
        // contain every section the single prompt used to.
        let combined = PlanGenerationService.planningRules(hasEvents: true)
            + PlanGenerationService.userPrompt(request(events: [event(14 * 60, 15 * 60)]))
        for section in ["PRIORITY RULES:", "DAY WINDOW:", "SAVED LOCATIONS & FACILITIES:",
                        "TODAY'S ANCHORS:", "COMMUTE:", "CHAINING & INTELLIGENCE",
                        "RESPOND WITH STRICT JSON", "BASELINE ROUTINE"] {
            XCTAssertTrue(combined.contains(section), "lost '\(section)' in the cache split")
        }
    }

    func testEventRulesStayConditional() {
        // Making these unconditional would have bought one cache entry instead
        // of two — at the price of feeding event rules into eventless days.
        let withEvents = PlanGenerationService.planningRules(hasEvents: true)
        let without = PlanGenerationService.planningRules(hasEvents: false)
        XCTAssertTrue(withEvents.contains("Events are FIXED ANCHORS"))
        XCTAssertFalse(without.contains("Events are FIXED ANCHORS"),
                       "eventless plans must not be given event rules")
    }

    // MARK: The tally

    func testHitRateAndCostRatio() throws {
        var d = PromptCacheStats.Day(read: 900, write: 100, uncached: 0, calls: 5)
        XCTAssertEqual(try XCTUnwrap(d.hitRate), 0.9, accuracy: 0.001)
        // 100 * 1.25 + 900 * 0.1 = 215, against 1000 uncached → 0.215
        XCTAssertEqual(try XCTUnwrap(d.costRatio), 0.215, accuracy: 0.001)

        // All writes, no hits: strictly worse than not caching at all. The
        // ratio must show that rather than flattering the number.
        d = PromptCacheStats.Day(read: 0, write: 1000, uncached: 0, calls: 1)
        XCTAssertEqual(try XCTUnwrap(d.costRatio), 1.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(d.hitRate), 0.0, accuracy: 0.001)
    }

    func testEmptyDayReportsNothingRatherThanZero() {
        let d = PromptCacheStats.Day()
        XCTAssertNil(d.hitRate, "no traffic is not a 0% hit rate")
        XCTAssertNil(d.costRatio)
    }
}
