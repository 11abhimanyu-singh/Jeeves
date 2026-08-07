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

    private func lunch(_ start: String, _ end: String) -> GeneratedBlock {
        GeneratedBlock(title: "Lunch", startTime: start, endTime: end, note: nil, isAnchor: false, kind: "lunch")
    }

    // MARK: the break after 90 minutes
    //
    // This replaced a prep-only breather that fired between two interview-prep
    // blocks and nowhere else, so 150 minutes of prep was caught and 150
    // minutes of anything else was not. The trigger is the LENGTH of the run
    // now. Note the deliberate consequence: two 45-minute prep blocks total
    // exactly 90 and are FINE — the old rule flagged them.

    func testAnHourAndAHalfOfWorkIsAllowedToRunUnbroken() {
        XCTAssertTrue(PlanRules.longRunViolations([
            b("Interview prep — Product Sense", "09:00", "09:45"),
            b("Interview prep — Execution", "09:45", "10:30"),
        ]).isEmpty, "90 minutes is the limit, not the trigger")
    }

    /// The user's own example: 150 minutes of prep must not run back to back.
    func testAHundredAndFiftyMinuteRunIsFlagged() {
        let v = PlanRules.longRunViolations([
            b("Interview prep — Product Sense", "09:00", "10:15"),
            b("Interview prep — Execution", "10:15", "11:30"),
        ])
        XCTAssertEqual(v.count, 1)
        XCTAssertTrue(v[0].contains("150 min"), v[0])
        XCTAssertTrue(v[0].contains("Product Sense"), "name where the run started, not just where it ended")
    }

    func testATenMinuteGapBreaksTheRun() {
        XCTAssertTrue(PlanRules.longRunViolations([
            b("Interview prep — Product Sense", "09:00", "10:15"),
            b("Interview prep — Execution", "10:25", "11:40"),
        ]).isEmpty)
    }

    func testAShorterGapIsNotABreak() {
        XCTAssertEqual(PlanRules.longRunViolations([
            b("Interview prep — Product Sense", "09:00", "10:15"),
            b("Interview prep — Execution", "10:20", "11:35"),
        ]).count, 1, "five minutes is not a break")
    }

    /// The exception that gives the rule its shape: lunch IS the break, so
    /// nothing is owed beside it. Adding a breather next to lunch would read as
    /// the app not noticing the meal it just scheduled.
    func testLunchCountsAsTheBreak() {
        XCTAssertTrue(PlanRules.longRunViolations([
            b("Reading", "10:00", "11:30"),
            lunch("11:30", "12:00"),
            b("Job applications", "12:00", "13:15"),
        ]).isEmpty, "150 minutes of work, but the meal sits in the middle of it")
    }

    func testTheGymAndACommuteAlsoResetTheRun() {
        for (title, kind) in [("Commute — home → gym", "commute"), ("Gym", "gym"), ("Free time", "free")] {
            XCTAssertTrue(PlanRules.longRunViolations([
                b("Reading", "09:00", "10:30"),
                GeneratedBlock(title: title, startTime: "10:30", endTime: "11:00",
                               note: nil, isAnchor: false, kind: kind),
                b("Job applications", "11:00", "12:15"),
            ]).isEmpty, "\(title) is already a break from work")
        }
    }

    /// One run, one complaint — otherwise a long afternoon reports the same
    /// fault once per block after the limit and the repair prompt fills with it.
    func testALongRunIsReportedOnce() {
        XCTAssertEqual(PlanRules.longRunViolations([
            b("A", "09:00", "10:00"), b("B", "10:00", "11:00"),
            b("C", "11:00", "12:00"), b("D", "12:00", "13:00"),
        ]).count, 2, "120 min trips it, then the count restarts and 120 more trips it again")
    }

    func testOverlapsAreLeftToTheOverlapCheck() {
        XCTAssertTrue(PlanRules.longRunViolations([
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
        // The KIND matters now: lunch, a commute and the gym are breaks, and
        // flattening everything to "activity" would make these tests enforce a
        // rule the app deliberately does not have.
        return blocks.map { b -> GeneratedBlock in
            let kind: String
            if b.title == "Lunch" { kind = "lunch" }
            else if b.title.localizedCaseInsensitiveContains("commute") { kind = "commute" }
            else if b.title == "Gym" { kind = "gym" }
            else if b.title.localizedCaseInsensitiveContains("free")
                        || b.title.localizedCaseInsensitiveContains("discretionary")
                        || b.title.localizedCaseInsensitiveContains("wind-down")
                        || b.title == "Sleep" { kind = "free" }
            else { kind = "activity" }
            return GeneratedBlock(title: b.title, startTime: hhmm(b.startMinute),
                                  endTime: hhmm(b.endMinute), note: nil,
                                  isAnchor: b.isAnchor, kind: kind)
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

    func testTheOfflinePlannerLeavesTheBreakToo() {
        let v = PlanRules.longRunViolations(
            asGenerated(DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: [])))
        XCTAssertTrue(v.isEmpty, v.joined(separator: "\n"))
    }

    func testTheBreakSurvivesAGymDayToo() {
        let v = PlanRules.longRunViolations(
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

    // MARK: commute + parking are non-negotiable

    private func plan(_ blocks: [GeneratedBlock]) -> GeneratedPlan {
        GeneratedPlan(blocks: blocks, dropped: [], shrunk: [], summary: "", boundaryTime: nil)
    }
    private func request(_ estimates: [String: Int]) -> PlanRequest {
        PlanRequest(userMessage: "", hasGymToday: false, gymMinute: nil, events: [],
                    locations: [], defaultCommuteMinutes: 30, commuteEstimates: estimates,
                    prepNeglectNote: nil)
    }

    /// A one-block plan trips other rules too (no lunch, nothing after an
    /// event). Only the travel-floor violations are under test here.
    private func travelViolations(_ blocks: [GeneratedBlock], _ estimates: [String: Int]) -> [String] {
        PlanValidation.severe(plan(blocks), request: request(estimates))
            .map(\.message)
            .filter { $0.contains("never trimmed") }
    }

    func testAShavedCommuteIsSevere() {
        let v = travelViolations([b("Commute Home → Gym", "10:00", "10:30")], ["Home→Gym": 30])
        XCTAssertEqual(v.count, 1, "30 measured + 10 parking = 40; 30 is short")
        XCTAssertTrue(v[0].contains("+ 10 min parking"), v[0])
    }

    func testAFullOutboundCommutePasses() {
        XCTAssertTrue(travelViolations([b("Commute Home → Gym", "10:00", "10:40")],
                                       ["Home→Gym": 30]).isEmpty)
    }

    func testTheTripHomeNeedsNoParkingAllowance() {
        XCTAssertTrue(travelViolations([b("Commute Gym → Home", "12:00", "12:30")],
                                       ["Gym→Home": 30]).isEmpty)
        XCTAssertEqual(travelViolations([b("Commute Gym → Home", "12:00", "12:20")],
                                        ["Gym→Home": 30]).count, 1,
                       "no parking on the way home, but the drive itself still can't shrink")
    }

    func testProseBlockTitlesStillMatchTheirRoute() {
        XCTAssertEqual(CommuteBuffer.matchRoute(blockTitle: "Commute to gym",
                                                in: ["Home→Gym": 42])?.minutes, 42)
        XCTAssertEqual(CommuteBuffer.matchRoute(blockTitle: "Commute home",
                                                in: ["Gym→Home": 38])?.minutes, 38)
        XCTAssertNil(CommuteBuffer.matchRoute(blockTitle: "Lunch", in: ["Home→Gym": 42]),
                     "only commute blocks are held to a travel floor")
    }

    // MARK: the gym is one block

    func testTheGymIsASingleAnchorBlock() {
        let blocks = DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: [])
        let gym = blocks.filter { $0.title.localizedCaseInsensitiveContains("gym")
                                  && !$0.title.localizedCaseInsensitiveContains("commute") }
        XCTAssertEqual(gym.count, 1, "mobility/weights/cardio are logged in Fitness, not planned separately")
        XCTAssertEqual(gym.first?.title, "Gym")
        XCTAssertEqual(gym.first?.startMinute, 11 * 60, "it starts when the user said")
        XCTAssertEqual(gym.first?.durationMinutes, 125, "20 + 70 + 35")
        XCTAssertTrue(gym.first?.isAnchor ?? false)
        XCTAssertEqual(gym.first?.note, "Mobility 20m · Weightlifting 70m · Cardio 35m",
                       "the parts still show, as a note")
    }

    func testDisablingAPartShortensTheOneBlock() {
        let blocks = DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: [],
                                         gymSession: [(name: "Weightlifting", minutes: 70)])
        let gym = blocks.first { $0.title == "Gym" }
        XCTAssertEqual(gym?.durationMinutes, 70)
        XCTAssertEqual(gym?.startMinute, 11 * 60)
        // Departure is now just drive + parking — nothing runs before the gym.
        XCTAssertEqual(blocks.first { $0.title == "Commute to gym" }?.startMinute, 11 * 60 - 40)
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

    /// Waking and starting work are different times. The prompt used to
    /// hardcode both — "cover 07:00–08:00" — so moving the start left an hour
    /// nobody owned, or put work before the sleep anchor ended.
    func testMorningRoutineWindowFollowsTheSetting() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: DayPreferences.dayStartKey)
        defer { saved == nil ? d.removeObject(forKey: DayPreferences.dayStartKey)
                             : d.set(saved, forKey: DayPreferences.dayStartKey) }

        d.set(8 * 60, forKey: DayPreferences.dayStartKey)
        XCTAssertEqual(DayPreferences.morningRoutineWindow?.start, 7 * 60)
        XCTAssertEqual(DayPreferences.morningRoutineWindow?.end, 8 * 60)

        d.set(9 * 60 + 30, forKey: DayPreferences.dayStartKey)
        XCTAssertEqual(DayPreferences.morningRoutineWindow?.end, 9 * 60 + 30,
                       "the routine stretches to meet the new start — no orphaned hour")

        // Starting work the moment you wake leaves no routine to place.
        d.set(DayPreferences.wakeMinute, forKey: DayPreferences.dayStartKey)
        XCTAssertNil(DayPreferences.morningRoutineWindow)
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
