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
                     b("Lunch", "12:00", "12:45", kind: "lunch"),
                     b("Appt", "14:00", "15:00", anchor: true, kind: "event"),
                     b("Commute home", "15:00", "15:40", kind: "commute")],
            dropped: ["Job applications", "Reading habit"], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: request(events: [event(14 * 60, 15 * 60)]))
            .contains { $0.message.contains("wasted") })
    }

    func testMiddayEventWithAfternoonWorkIsFine() {
        let plan = GeneratedPlan(
            blocks: [b("Interview prep — Reading", "08:00", "09:30", anchor: true),
                     b("Lunch", "12:00", "12:45", kind: "lunch"),
                     b("Appt", "14:00", "15:00", anchor: true, kind: "event"),
                     b("Commute home", "15:00", "15:40", kind: "commute"),
                     b("Reading habit", "15:40", "17:10")],
            dropped: ["Job applications"], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanValidation.severe(plan, request: request(events: [event(14 * 60, 15 * 60)])).isEmpty)
    }
}
