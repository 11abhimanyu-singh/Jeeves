//
//  StaleCommuteTests.swift
//  JeevesTests
//
//  The bug these pin was found by reading a screenshot, not by any test:
//
//    10:22  Commute Home → Gym   "18-min trip to arrive for mobility."
//    10:40  Interview prep — practice
//
//  There was no gym block anywhere in that plan. The gym had been moved to the
//  evening; the morning commute to it had already elapsed, so the mid-day
//  re-plan locked it in as "already done" and built the rest of the day around
//  a journey to somewhere the day no longer went.
//
//  It passed every deterministic rule the app had. Chronological, no overlaps,
//  no gaps, commute duration matching its own note exactly. Elapsed was being
//  treated as automatically preservable, and nothing checked that a journey
//  arrived anywhere.
//

import XCTest
@testable import Jeeves

final class StaleCommuteTests: XCTestCase {

    private func blk(_ title: String, _ start: String, _ end: String,
                     kind: String = "activity") -> GeneratedBlock {
        GeneratedBlock(title: title, startTime: start, endTime: end,
                       note: nil, isAnchor: false, kind: kind)
    }

    /// The plan as it stood before the gym moved: morning commute, morning gym.
    private var morningGymPlan: GeneratedPlan {
        GeneratedPlan(blocks: [
            blk("Interview prep — Reading", "08:00", "09:30"),
            blk("Job applications", "09:30", "10:22"),
            blk("Commute Home → Gym", "10:22", "10:40", kind: "commute"),
            blk("Gym — Mobility", "10:40", "11:00", kind: "gym"),
            blk("Gym — Weightlifting", "11:00", "12:10", kind: "gym"),
        ], dropped: [], shrunk: [], summary: "", boundaryTime: nil)
    }

    // MARK: The lock

    func testCommuteToAMovedGymIsNotPreserved() {
        // Gym moved to 17:00. Re-planning at 12:30 — the morning commute has
        // long elapsed, but it is a journey the day no longer makes.
        let anchors = PlanCoordinator.arrivalAnchors(gymMinute: 17 * 60, eventStarts: [])
        let locked = PlanCoordinator.lockedBlocks(morningGymPlan, endedBy: 12 * 60 + 30,
                                                  stillArrivingAt: anchors)
        XCTAssertFalse(locked.contains { $0.kind == "commute" },
                       "the morning commute to a gym that moved to the evening must not be locked in")
        XCTAssertTrue(locked.contains { $0.title == "Job applications" },
                      "work that genuinely happened is still preserved")
    }

    func testCommuteToAnUnchangedGymIsPreserved() {
        // Same plan, gym still at 11:00 — the commute really did deliver you
        // there, so it stays. The fix must not throw away real history.
        let anchors = PlanCoordinator.arrivalAnchors(gymMinute: 11 * 60, eventStarts: [])
        let locked = PlanCoordinator.lockedBlocks(morningGymPlan, endedBy: 12 * 60 + 30,
                                                  stillArrivingAt: anchors)
        XCTAssertTrue(locked.contains { $0.title == "Commute Home → Gym" },
                      "a commute whose arrival still stands must be preserved")
    }

    func testRestDayOrphansEveryElapsedCommute() {
        // Gym switched off entirely: nothing is anchored, so nothing the
        // commute was for exists. An empty anchor list must mean "orphaned",
        // not "skip the check".
        let locked = PlanCoordinator.lockedBlocks(morningGymPlan, endedBy: 12 * 60 + 30,
                                                  stillArrivingAt: [])
        XCTAssertFalse(locked.contains { $0.kind == "commute" })
    }

    func testNonCommuteBlocksAreNeverFilteredByAnchors() {
        let locked = PlanCoordinator.lockedBlocks(morningGymPlan, endedBy: 12 * 60 + 30,
                                                  stillArrivingAt: [])
        XCTAssertEqual(locked.map(\.title),
                       ["Interview prep — Reading", "Job applications", "Gym — Mobility", "Gym — Weightlifting"],
                       "only commutes are subject to the arrival check")
    }

    func testArrivalAnchorsCoverMobilityNotJustWeightlifting() {
        // A Home→Gym commute arrives for MOBILITY, 20 min before the time the
        // user actually enters. Anchoring only on weightlifting would drop
        // every legitimate gym commute.
        let anchors = PlanCoordinator.arrivalAnchors(gymMinute: 17 * 60, eventStarts: [9 * 60])
        XCTAssertTrue(anchors.contains(17 * 60))
        XCTAssertTrue(anchors.contains(16 * 60 + 40))
        XCTAssertTrue(anchors.contains(9 * 60))
    }

    // MARK: The invariant

    private func request(gym: Int?) -> PlanRequest {
        PlanRequest(userMessage: "", hasGymToday: gym != nil, gymMinute: gym, events: [],
                    locations: [], defaultCommuteMinutes: 30, commuteEstimates: [:],
                    prepNeglectNote: nil)
    }

    func testCommuteToNowhereIsASevereViolation() {
        // The screenshot, exactly: a journey to the gym followed by desk work.
        let plan = GeneratedPlan(blocks: [
            blk("Commute Home → Gym", "10:22", "10:40", kind: "commute"),
            blk("Interview prep — practice", "10:40", "12:20"),
            blk("Lunch", "12:30", "13:00", kind: "lunch"),
        ], dropped: [], shrunk: [], summary: "", boundaryTime: nil)

        let violations = PlanValidation.validate(plan, request: request(gym: nil))
        XCTAssertTrue(violations.contains { $0.message.contains("must arrive somewhere the day actually goes") },
                      "a commute to the gym followed by non-gym work must be caught")
    }

    func testCommuteFollowedByTheGymIsClean() {
        let plan = GeneratedPlan(blocks: [
            blk("Commute Home → Gym", "10:22", "10:40", kind: "commute"),
            blk("Gym — Mobility", "10:40", "11:00", kind: "gym"),
            blk("Gym — Weightlifting", "11:00", "12:10", kind: "gym"),
            blk("Gym — Cardio run", "12:10", "12:45", kind: "gym"),
            blk("Lunch", "12:45", "13:15", kind: "lunch"),
        ], dropped: [], shrunk: [], summary: "", boundaryTime: nil)

        let violations = PlanValidation.validate(plan, request: request(gym: 11 * 60))
        XCTAssertFalse(violations.contains { $0.message.contains("must arrive somewhere") },
                       "a commute that does reach the gym is fine")
    }

    func testReturnLegIsNotChecked() {
        // "Gym → Home" legitimately precedes anything at all.
        let plan = GeneratedPlan(blocks: [
            blk("Commute Gym → Home", "12:45", "13:05", kind: "commute"),
            blk("Lunch", "13:05", "13:35", kind: "lunch"),
        ], dropped: [], shrunk: [], summary: "", boundaryTime: nil)

        let violations = PlanValidation.validate(plan, request: request(gym: nil))
        XCTAssertFalse(violations.contains { $0.message.contains("must arrive somewhere") },
                       "the journey home is not a journey to the gym")
    }
}
