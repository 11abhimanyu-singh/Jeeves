//
//  LiveAITests.swift
//  JeevesTests
//
//  Opt-in re-verification of the network/AI integrations that can't live in
//  the normal suite (they need real keys, cost money, and are slow — and the
//  LLM ones are inherently a bit non-deterministic). Each test self-skips when
//  its key isn't in the Keychain, so on a keyless machine (CI) they no-op
//  rather than fail.
//
//  Routine fast suite (excludes these):
//    xcodebuild test -scheme Jeeves -destination '…' -skip-testing:JeevesTests/LiveAITests
//
//  On-demand live run (only these, ~90s):
//    xcodebuild test -scheme Jeeves -destination '…' -only-testing:JeevesTests/LiveAITests
//

import XCTest
@testable import Jeeves

final class LiveAITests: XCTestCase {

    // MARK: Claude

    func testLiveChatRoundTrip() async throws {
        try XCTSkipUnless(KeychainService.hasAPIKey, "no Anthropic key in Keychain")
        let reply = try await JeevesChatService.send(history: [], newMessage: "Reply with exactly the word: pong")
        print("=== chat reply: \(reply) ===")
        XCTAssertFalse(reply.isEmpty)
    }

    func testLiveExtractionParsesTimeAndVenue() async throws {
        try XCTSkipUnless(KeychainService.hasAPIKey, "no Anthropic key in Keychain")
        let anchors = try await AnchorExtractionService.extract(
            from: "I have to go to MLR Convention Centre at 7 pm, plan my day.",
            existingTitles: []
        )
        print("=== extracted \(anchors.events.count) event(s) ===")
        XCTAssertFalse(anchors.events.isEmpty)
        XCTAssertEqual(anchors.events.first?.startTime, "19:00")
        XCTAssertTrue((anchors.events.first?.venue ?? "").localizedCaseInsensitiveContains("MLR"))
    }

    func testLivePlanGenerationProducesCoherentPlan() async throws {
        try XCTSkipUnless(KeychainService.hasAPIKey, "no Anthropic key in Keychain")
        let req = PlanRequest(
            userMessage: "Normal day, gym at 11.",
            hasGymToday: true, gymMinute: 11 * 60,
            events: [], locations: [],
            defaultCommuteMinutes: 30, commuteEstimates: [:],
            prepNeglectNote: nil
        )
        let plan = try await PlanGenerationService.generate(req)
        print("=== plan: \(plan.blocks.count) blocks, summary \(plan.summary.prefix(60))… ===")
        XCTAssertFalse(plan.blocks.isEmpty)
        XCTAssertFalse(plan.summary.isEmpty)
        // Chronological, non-overlapping.
        let mins = plan.blocks.compactMap { b -> (Int, Int)? in
            guard let s = b.startMinute, let e = b.endMinute else { return nil }
            return (s, e)
        }
        for (prev, next) in zip(mins, mins.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.0, prev.1, "blocks must not overlap")
        }
    }

    // MARK: Google Maps (Routes API)

    func testLiveMapsCommute() async throws {
        try XCTSkipUnless(KeychainService.hasGoogleMapsAPIKey, "no Google Maps key in Keychain")
        let mins = await GoogleMapsService.commuteMinutes(
            from: "Koramangala, Bangalore",
            to: "MLR Convention Centre, Whitefield, Bangalore"
        )
        print("=== maps commute: \(String(describing: mins)) min ===")
        let m = try XCTUnwrap(mins, "Routes API should return a duration")
        XCTAssertGreaterThan(m, 0)
        XCTAssertLessThan(m, 300, "sanity: a city commute is under 5 hours")
    }
}
