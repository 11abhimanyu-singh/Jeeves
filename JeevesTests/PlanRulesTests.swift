//
//  PlanRulesTests.swift
//  JeevesTests
//
//  The breather between prep blocks, the parking buffer, and the two
//  preferences that used to be constants in three files.
//

import XCTest
@testable import Jeeves

final class PlanRulesTests: XCTestCase {

    private func b(_ title: String, _ start: String, _ end: String) -> GeneratedBlock {
        GeneratedBlock(title: title, startTime: start, endTime: end, note: nil, isAnchor: false, kind: "activity")
    }

    // MARK: the breather

    func testBackToBackPrepBlocksAreFlagged() {
        let v = PlanRules.prepBreatherViolations([
            b("Interview prep — Product Sense", "09:00", "09:45"),
            b("Interview prep — Execution", "09:45", "10:30"),
        ])
        XCTAssertEqual(v.count, 1)
        XCTAssertTrue(v[0].contains("0 min"), v[0])
    }

    func testTenMinutesBetweenPrepBlocksPasses() {
        XCTAssertTrue(PlanRules.prepBreatherViolations([
            b("Interview prep — Product Sense", "09:00", "09:45"),
            b("Interview prep — Execution", "09:55", "10:40"),
        ]).isEmpty)
    }

    func testAGapShorterThanTheBreatherIsStillFlagged() {
        XCTAssertEqual(PlanRules.prepBreatherViolations([
            b("Interview prep — Strategy", "09:00", "09:45"),
            b("Interview prep — Behavioral", "09:50", "10:35"),
        ]).count, 1, "5 minutes is not a breather")
    }

    /// The rule is about prep, not about every activity — a routine where
    /// nothing may touch anything would have gaps all day.
    func testNonPrepNeighboursMayRunContiguously() {
        XCTAssertTrue(PlanRules.prepBreatherViolations([
            b("Chores", "09:00", "10:00"),
            b("Lunch", "10:00", "10:30"),
            b("Job applications", "10:30", "11:45"),
        ]).isEmpty)
    }

    func testPrepBlocksSeparatedBySomethingElseAreFine() {
        XCTAssertTrue(PlanRules.prepBreatherViolations([
            b("Interview prep — Product Sense", "09:00", "09:45"),
            b("Lunch", "12:30", "13:00"),
            b("Interview prep — Execution", "13:00", "13:45"),
        ]).isEmpty, "the gap between them is hours; what sits in it is irrelevant")
    }

    func testOverlapsAreLeftToTheOverlapCheck() {
        XCTAssertTrue(PlanRules.prepBreatherViolations([
            b("Interview prep — Product Sense", "09:00", "10:00"),
            b("Interview prep — Execution", "09:30", "10:30"),
        ]).isEmpty, "reporting the same fault twice helps nobody")
    }

    func testTheReadingHabitIsNotAPrepBlock() {
        XCTAssertFalse(PlanRules.isPrepBlock(title: "Reading habit"))
        XCTAssertTrue(PlanRules.isPrepBlock(title: "Interview prep — Reading"))
        XCTAssertTrue(PlanRules.isPrepBlock(title: "Interview prep — Behavioral"))
    }

    /// Found in acceptance testing, not by the unit tests: the rule was stated
    /// in the prompt and checked by PlanValidation, but the deterministic
    /// offline planner packed prep blocks straight into each other — Execution
    /// 14:40, Strategy 15:15, Behavioral 15:40, no breather anywhere.
    /// GeneratedBlock parses "HH:MM" in 24-hour form. DayPlanner.label emits
    /// "2:40 PM", which parses to nil — and a nil start is SKIPPED by the
    /// breather check, so converting with it produced a test that examined
    /// nothing and passed. Build the strings the parser actually reads.
    private func asGenerated(_ blocks: [PlanBlock]) -> [GeneratedBlock] {
        func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", (m / 60) % 24, m % 60) }
        return blocks.map {
            GeneratedBlock(title: $0.title, startTime: hhmm($0.startMinute),
                           endTime: hhmm($0.endMinute), note: nil,
                           isAnchor: $0.isAnchor, kind: "activity")
        }
    }

    func testConversionActuallyParses() {
        let blocks = asGenerated(DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: []))
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertTrue(blocks.allSatisfy { $0.startMinute != nil },
                      "if these don't parse, every check built on them is vacuous")
        XCTAssertTrue(blocks.contains { PlanRules.isPrepBlock(title: $0.title) },
                      "and there must be prep blocks to check in the first place")
    }

    func testTheOfflinePlannerLeavesTheBreatherToo() {
        let v = PlanRules.prepBreatherViolations(
            asGenerated(DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: [])))
        XCTAssertTrue(v.isEmpty, v.joined(separator: "\n"))
    }

    func testTheBreatherSurvivesAGymDayToo() {
        let v = PlanRules.prepBreatherViolations(
            asGenerated(DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: [])))
        XCTAssertTrue(v.isEmpty, v.joined(separator: "\n"))
    }

    // MARK: parking

    func testOutboundTripsGetParkingAndTheTripHomeDoesNot() {
        XCTAssertTrue(CommuteBuffer.needsParking(route: "Home→Gym"))
        XCTAssertTrue(CommuteBuffer.needsParking(route: "Home → MLR Convention Centre"))
        XCTAssertFalse(CommuteBuffer.needsParking(route: "Gym→Home"))
        XCTAssertFalse(CommuteBuffer.needsParking(route: "Event → home in Indiranagar"))
    }

    func testDoorToDoorAddsTheBufferOnlyOneWay() {
        XCTAssertEqual(CommuteBuffer.doorToDoor(minutes: 42, route: "Home→Gym"), 52)
        XCTAssertEqual(CommuteBuffer.doorToDoor(minutes: 42, route: "Gym→Home"), 42)
    }

    func testAKeyThatIsNotARouteAsksForNoParking() {
        XCTAssertFalse(CommuteBuffer.needsParking(route: "Gym"))
        XCTAssertNil(CommuteBuffer.destination(of: "Gym"))
    }

    // MARK: preferences

    func testDayStartFallsBackTo8amWhenUnset() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: DayPreferences.dayStartKey)
        defer { saved == nil ? d.removeObject(forKey: DayPreferences.dayStartKey)
                             : d.set(saved, forKey: DayPreferences.dayStartKey) }

        d.removeObject(forKey: DayPreferences.dayStartKey)
        XCTAssertEqual(DayPreferences.dayStartMinute, 8 * 60)
        // 0 is what `integer(forKey:)` returns for "never set" — it must not be
        // read as a legitimate midnight start.
        d.set(0, forKey: DayPreferences.dayStartKey)
        XCTAssertEqual(DayPreferences.dayStartMinute, 8 * 60)

        d.set(6 * 60 + 30, forKey: DayPreferences.dayStartKey)
        XCTAssertEqual(DayPreferences.dayStartMinute, 390)
        XCTAssertEqual(Baseline.dayStartMinute, 390, "the planner reads the same one")
        XCTAssertEqual(DayPlanner.dayStartMinute, 390)
        XCTAssertEqual(PlanValidation.dayStart, 390, "and so does the validator")
    }

    func testBodyWeightDefaultsTo120() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: DayPreferences.bodyWeightKey)
        defer { saved == nil ? d.removeObject(forKey: DayPreferences.bodyWeightKey)
                             : d.set(saved, forKey: DayPreferences.bodyWeightKey) }

        d.removeObject(forKey: DayPreferences.bodyWeightKey)
        XCTAssertEqual(DayPreferences.bodyWeightKg, 120)
        d.set(82.5, forKey: DayPreferences.bodyWeightKey)
        XCTAssertEqual(DayPreferences.bodyWeightKg, 82.5)
    }

    func testClockFormatsMinutes() {
        XCTAssertEqual(DayPreferences.clock(8 * 60), "08:00")
        XCTAssertEqual(DayPreferences.clock(6 * 60 + 30), "06:30")
    }
}
