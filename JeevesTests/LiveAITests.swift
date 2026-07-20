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
import SwiftData
@testable import Jeeves

final class LiveAITests: XCTestCase {

    // MARK: Event → Day Planner (the chat "Plan my day" commit path)

    /// Adds an event, runs the same PlanCoordinator call the chat uses, commits
    /// the result to a day's DailyPlanState, and confirms the Day Planner would
    /// then show a plan that reflects the event. This is the end-to-end "add an
    /// event, and the day planner changes" behavior — Claude-driven, so live.
    @MainActor
    func testEventCommitsToDayPlanner() async throws {
        try XCTSkipUnless(KeychainService.hasAPIKey, "no Anthropic key in Keychain")
        let day = Date().startOfDay
        let event = DailyEvent(date: day, title: "Baithak live",
                               startMinute: 19 * 60, endMinute: 21 * 60,
                               destinationAddress: "MLR Convention Centre, Bengaluru",
                               outboundStart: .home, source: .manual)

        // The Day Planner starts with no committed plan.
        let state = DailyPlanState(date: day, hasGymToday: false, gymMinute: nil)
        XCTAssertNil(state.plan, "planner should start empty")

        // Same call the chat's Plan my day makes.
        let result = await PlanCoordinator.generate(.init(
            hasGym: false, gymMinute: nil, events: [event], locations: [], prepSessions: []
        ))
        XCTAssertFalse(result.isOffline, "should be a live Claude plan when the key is present")
        XCTAssertFalse(result.plan.blocks.isEmpty)
        XCTAssertTrue(result.plan.blocks.contains { $0.kind == "event" }, "the event should be anchored in the plan")

        // Commit → the Day Planner now reads a plan for this day.
        state.storePlan(result.plan, isOffline: result.isOffline)
        XCTAssertNotNil(state.plan, "planner should now show the committed plan")
        XCTAssertEqual(state.plan?.blocks.count, result.plan.blocks.count)
        XCTAssertTrue(state.plan?.blocks.contains { $0.title.localizedCaseInsensitiveContains("Baithak") } ?? false,
                      "the committed plan the planner shows should include the added event")
    }

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

    /// Regression: a MIDDAY event must not discard the rest of the day. The
    /// planner used to treat the event's departure as the end of the day and
    /// drop everything after it (including a Must-do), leaving the whole
    /// afternoon empty. A correct plan keeps the morning Must-do and fills the
    /// hours after the event returns home.
    func testMiddayEventUsesTheWholeDay() async throws {
        try XCTSkipUnless(KeychainService.hasAPIKey, "no Anthropic key in Keychain")
        let appt = DailyEvent(date: Date().startOfDay, title: "Dr Sree Lakshmi",
                              startMinute: 14 * 60, endMinute: 15 * 60,
                              destinationAddress: "Silent Monkee, Bengaluru",
                              outboundStart: .home, source: .manual)
        let plan = try await PlanGenerationService.generate(PlanRequest(
            userMessage: "Gym at 11, appointment at 2pm.",
            hasGymToday: true, gymMinute: 11 * 60,
            events: [appt], locations: [],
            defaultCommuteMinutes: 30, commuteEstimates: ["Home→Dr Sree Lakshmi": 40],
            prepNeglectNote: nil
        ))
        // Must-do reading is kept, in the morning.
        XCTAssertFalse(plan.dropped.contains { $0.localizedCaseInsensitiveContains("Reading") },
                       "Must-do reading dropped: \(plan.dropped)")
        XCTAssertTrue(plan.blocks.contains { $0.title.localizedCaseInsensitiveContains("Reading") && ($0.startMinute ?? 0) < 11 * 60 })
        // The afternoon after the 15:00 appointment holds real work.
        XCTAssertTrue(plan.blocks.contains { b in
            (b.startMinute ?? 0) >= 15 * 60 && !["event", "commute", "free"].contains(b.kind)
        }, "afternoon/evening after the appointment should hold work, not be discarded")
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
