//
//  PlanValidationTests.swift
//  JeevesTests
//
//  The validator is pure and deterministic, so it's fully unit-testable in the
//  fast suite — no key, no network. These lock in that it catches the real
//  failures and doesn't false-positive on a good plan.
//

import XCTest
@testable import Jeeves

final class PlanValidationTests: XCTestCase {

    private func b(_ title: String, _ start: String, _ end: String, anchor: Bool = false, kind: String = "activity") -> GeneratedBlock {
        GeneratedBlock(title: title, startTime: start, endTime: end, note: nil, isAnchor: anchor, kind: kind)
    }

    private func request(events: [DailyEvent] = []) -> PlanRequest {
        PlanRequest(userMessage: "", hasGymToday: false, gymMinute: nil, events: events,
                    locations: [], defaultCommuteMinutes: 30, commuteEstimates: [:], prepNeglectNote: nil)
    }

    private func event(_ start: Int, _ end: Int, title: String = "Appt") -> DailyEvent {
        DailyEvent(date: Date().startOfDay, title: title, startMinute: start, endMinute: end,
                   destinationAddress: "somewhere", outboundStart: .home, source: .manual)
    }

    // MARK: Happy path

    func testValidPlanHasNoViolations() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Job applications", "09:30", "11:00"),
                     b("Lunch", "13:00", "13:45", kind: "lunch"),
                     b("Free time", "13:45", "20:30", kind: "free")],
            dropped: [], shrunk: [], summary: "ok", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.validate(plan, request: request()).isEmpty)
    }

    // MARK: Severe violations

    func testOverlapIsSevere() {
        let plan = GeneratedPlan(
            blocks: [b("A", "08:00", "10:00"), b("B", "09:30", "11:00"), b("Lunch", "13:00", "13:45", kind: "lunch")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertFalse(PlanValidation.severe(plan, request: request()).isEmpty)
    }

    func testDroppedMustDoIsSevere() {
        let plan = GeneratedPlan(
            blocks: [b("Lunch", "13:00", "13:45", kind: "lunch")],
            dropped: ["Interview prep — Reading (MUST-DO — could not be placed)", "Chores"],
            shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: request()).contains { $0.message.contains("Must-do dropped") })
    }

    func testActivityPastBoundaryIsSevere() {
        let plan = GeneratedPlan(
            blocks: [b("Lunch", "13:00", "13:45", kind: "lunch"), b("Reading habit", "20:00", "21:00")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: request()).contains { $0.message.contains("past 20:30") })
    }

    func testLunchPastDeadlineIsSevere() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Lunch", "16:45", "17:30", kind: "lunch")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: request()).contains { $0.message.contains("14:30") })
    }

    func testLunchBeforeDeadlineIsFine() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Lunch", "13:00", "13:45", kind: "lunch")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertFalse(PlanValidation.severe(plan, request: request()).contains { $0.message.contains("14:30") })
    }

    func testMissingLunchIsSevere() {
        let plan = GeneratedPlan(
            blocks: [b("Job applications", "09:00", "10:30")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: request()).contains { $0.message.contains("Lunch") })
    }

    func testDroppedEventIsSevere() {
        // One event given, but no event block in the plan.
        let plan = GeneratedPlan(
            blocks: [b("Lunch", "13:00", "13:45", kind: "lunch")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: request(events: [event(14 * 60, 15 * 60)])).contains { $0.message.contains("event") })
    }

    func testMiddayEventWithNoAfternoonWorkIsSevere() {
        // Event 14:00–15:00, something dropped, nothing productive after → the bug.
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Lunch", "12:30", "13:00", kind: "lunch"),
                     b("Appt", "14:00", "15:00", anchor: true, kind: "event"),
                     b("Commute home", "15:00", "15:40", kind: "commute")],
            dropped: ["Job applications", "Reading habit"], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: request(events: [event(14 * 60, 15 * 60)]))
            .contains { $0.message.contains("wasted") })
    }

    func testMiddayEventWithAfternoonWorkIsFine() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Lunch", "12:30", "13:00", kind: "lunch"),
                     b("Appt", "14:00", "15:00", anchor: true, kind: "event"),
                     b("Commute home", "15:00", "15:40", kind: "commute"),
                     b("Reading habit", "15:40", "17:10")],
            dropped: ["Job applications"], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: request(events: [event(14 * 60, 15 * 60)])).isEmpty)
    }

    // MARK: Gym durations are pinned (never compressed to fit the day)

    private func gymRequest(gym: Int = 19 * 60) -> PlanRequest {
        PlanRequest(userMessage: "", hasGymToday: true, gymMinute: gym, events: [],
                    locations: [], defaultCommuteMinutes: 30, commuteEstimates: [:], prepNeglectNote: nil)
    }

    func testCompressedWeightliftingIsSevere() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Lunch", "13:00", "13:30", kind: "lunch"),
                     b("Weightlifting", "19:00", "19:45", anchor: true, kind: "gym")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: gymRequest())
            .contains { $0.message.contains("70-min") }, "45-min weightlifting must be flagged")
    }

    func testGymDayWithoutWeightliftingIsSevere() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Lunch", "13:00", "13:30", kind: "lunch")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: gymRequest())
            .contains { $0.message.contains("no weightlifting") })
    }

    /// A 19:00 gym legitimately runs past 20:30 — the boundary applies to WORK.
    /// The full uncompressed routine (incl. the at-home shower at 21:15) must
    /// produce zero severe violations.
    func testLateGymRunningPastBoundaryIsFine() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Lunch", "13:00", "13:30", kind: "lunch"),
                     b("Commute to gym", "18:10", "18:40", kind: "commute"),
                     b("Mobility", "18:40", "19:00", kind: "gym"),
                     b("Weightlifting", "19:00", "20:10", anchor: true, kind: "gym"),
                     b("Cardio", "20:10", "20:45", kind: "gym"),
                     b("Commute home", "20:45", "21:15", kind: "commute"),
                     b("Evening shower", "21:15", "21:35", kind: "activity"),
                     b("Free time", "21:35", "23:00", kind: "free"),
                     b("Sleep", "23:00", "07:00", anchor: true, kind: "sleep")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: gymRequest()).isEmpty,
                      "uncompressed late-gym routine must not trip the 20:30 work boundary")
    }

    /// The shower exemption is for a ≤30-min hygiene block — a long "shower"-
    /// titled activity is still work and must not slip past the 20:30 boundary.
    func testLongShowerTitledWorkPastBoundaryIsStillSevere() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Lunch", "13:00", "13:30", kind: "lunch"),
                     b("Shower + emails", "20:30", "22:30")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: request())
            .contains { $0.message.contains("runs past 20:30") },
            "a 2-hour 'shower' activity is work — the exemption must not apply")
    }

    /// An EVENT with "lift"/"weight" in its title must not satisfy (or trip)
    /// the pinned-weightlifting check — only gym-kind blocks count.
    func testEventTitledWeightliftingDoesNotSatisfyGymCheck() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Lunch", "13:00", "13:30", kind: "lunch"),
                     b("Weightlifting seminar", "15:00", "15:45", anchor: true, kind: "event")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        let severe = PlanValidation.severe(plan, request: gymRequest())
        XCTAssertTrue(severe.contains { $0.message.contains("no weightlifting") },
                      "a 45-min seminar EVENT must not stand in for the workout")
        XCTAssertFalse(severe.contains { $0.message.contains("70-min") },
                       "…nor be flagged as a compressed workout")
    }

    /// Work wedged into the middle of the gym routine (or any time gap between
    /// gym blocks) is a severe violation — the gym is one contiguous sequence.
    func testSplitGymRoutineIsSevere() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Mobility", "10:40", "11:00", kind: "gym"),
                     b("Weightlifting", "11:00", "12:10", anchor: true, kind: "gym"),
                     b("Job applications", "12:10", "12:40"),
                     b("Cardio", "12:40", "13:15", kind: "gym"),
                     b("Lunch", "13:15", "13:45", kind: "lunch")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: gymRequest(gym: 11 * 60))
            .contains { $0.message.contains("split") },
            "job applications wedged between weightlifting and cardio must be flagged")
    }

    /// Overlapping gym blocks are an overlap (rule 1), NOT a "split" — the
    /// contiguity check must only fire on genuine gaps, or it double-reports.
    func testOverlappingGymBlocksReportOverlapNotSplit() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Mobility", "10:40", "11:00", kind: "gym"),
                     b("Weightlifting", "11:00", "12:10", anchor: true, kind: "gym"),
                     b("Cardio", "12:00", "12:35", kind: "gym"),   // overlaps weightlifting
                     b("Lunch", "13:00", "13:30", kind: "lunch")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        let severe = PlanValidation.severe(plan, request: gymRequest(gym: 11 * 60))
        XCTAssertTrue(severe.contains { $0.message.contains("overlaps") }, "the overlap must be reported")
        XCTAssertFalse(severe.contains { $0.message.contains("split") }, "an overlap must not also be called a split")
    }

    /// The contiguous version of the same routine is clean — splitting a LONG
    /// activity around the gym is fine; only splitting the gym itself is not.
    func testContiguousGymWithSplitActivityAroundItIsFine() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Interview prep — practice (part 1 of 120)", "09:30", "10:40"),
                     b("Mobility", "10:40", "11:00", kind: "gym"),
                     b("Weightlifting", "11:00", "12:10", anchor: true, kind: "gym"),
                     b("Cardio", "12:10", "12:45", kind: "gym"),
                     b("Lunch", "13:00", "13:30", kind: "lunch"),
                     b("Interview prep — practice (part 2 of 120)", "13:30", "14:20")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: gymRequest(gym: 11 * 60)).isEmpty,
                      "practice split around the gym + lunch is correct scheduling")
    }

    /// After ~21:00 the full routine can't precede 23:00 sleep — the pinned-
    /// duration rule steps aside instead of making the rule set unsatisfiable.
    func testVeryLateGymSkipsPinnedDurationRule() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Lunch", "13:00", "13:30", kind: "lunch"),
                     b("Weightlifting", "22:00", "22:40", anchor: true, kind: "gym")],
            dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: gymRequest(gym: 22 * 60)).isEmpty)
    }
}
