//
//  PlanModelsTests.swift
//  JeevesTests
//
//  Pure-logic coverage for the plan model layer: HH:MM parsing, the
//  baseline-routine invariants, and Codable round-tripping (which is what
//  lets a generated plan survive in a persisted chat turn).
//

import XCTest
@testable import Jeeves

final class PlanModelsTests: XCTestCase {

    // MARK: HH:MM parsing

    func testMinutesParsesValidTimes() {
        XCTAssertEqual(GeneratedBlock.minutes(from: "08:00"), 480)
        XCTAssertEqual(GeneratedBlock.minutes(from: "14:30"), 870)
        XCTAssertEqual(GeneratedBlock.minutes(from: "00:00"), 0)
        XCTAssertEqual(GeneratedBlock.minutes(from: "23:59"), 1439)
        XCTAssertEqual(GeneratedBlock.minutes(from: "9:05"), 545) // single-digit hour
    }

    func testMinutesRejectsMalformed() {
        XCTAssertNil(GeneratedBlock.minutes(from: "1200"))   // no colon
        XCTAssertNil(GeneratedBlock.minutes(from: "noon"))
        XCTAssertNil(GeneratedBlock.minutes(from: ""))
        XCTAssertNil(GeneratedBlock.minutes(from: "12:xx"))
    }

    // MARK: Baseline routine (PRD §5.1)

    func testBaselineHasBothMustDosAndCorrectWindow() {
        let mustDos = Baseline.activities.filter { $0.tier == .mustDo }.map(\.name)
        XCTAssertTrue(mustDos.contains("Lunch"), "Lunch must be a Must-do")
        XCTAssertTrue(mustDos.contains("Interview prep — Reading"), "morning reading must be a Must-do")
        XCTAssertEqual(Baseline.dayStartMinute, 8 * 60)
        XCTAssertEqual(Baseline.normalBoundaryMinute, 20 * 60 + 30)
    }

    func testBaselinePracticeBlockIs120Important() {
        let practice = Baseline.activities.first { $0.name.contains("practice") }
        XCTAssertEqual(practice?.durationMinutes, 120)
        XCTAssertEqual(practice?.tier, .important)
    }

    // MARK: Codable round-trip (persistence)

    func testGeneratedPlanRoundTrips() throws {
        let plan = GeneratedPlan(
            blocks: [
                GeneratedBlock(title: "Reading", startTime: "08:00", endTime: "09:30", note: "peak", isAnchor: true, kind: "activity"),
                GeneratedBlock(title: "Movie", startTime: "14:00", endTime: "17:00", note: nil, isAnchor: true, kind: "event"),
            ],
            dropped: ["Chores"], shrunk: ["practice 120→70"],
            summary: "A tight day.", boundaryTime: "12:30"
        )
        let data = try JSONEncoder().encode(plan)
        let back = try JSONDecoder().decode(GeneratedPlan.self, from: data)

        XCTAssertEqual(back.blocks.count, 2)
        XCTAssertEqual(back.blocks[0].title, "Reading")
        XCTAssertEqual(back.blocks[0].startMinute, 480)
        XCTAssertEqual(back.blocks[1].kind, "event")
        XCTAssertEqual(back.dropped, ["Chores"])
        XCTAssertEqual(back.shrunk, ["practice 120→70"])
        XCTAssertEqual(back.summary, "A tight day.")
        XCTAssertEqual(back.boundaryTime, "12:30")
    }
}
