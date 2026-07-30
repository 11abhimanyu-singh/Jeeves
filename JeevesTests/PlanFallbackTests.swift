//
//  PlanFallbackTests.swift
//  JeevesTests
//
//  The offline fallback must respect timed events: it used to be
//  event-blind, scheduling interview prep on top of a 2 PM appointment
//  whenever the API was down.
//

import XCTest
@testable import Jeeves

@MainActor
final class PlanFallbackTests: XCTestCase {

    private func minutes(_ t: String?) -> Int? {
        guard let t else { return nil }
        let p = t.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : nil
    }

    func testTimedEventIsCarvedInAsAnchor() {
        let event = DailyEvent(date: Date(), title: "Dentist",
                               startMinute: 14 * 60, endMinute: 15 * 60,
                               destinationAddress: "Indiranagar")
        let plan = PlanCoordinator.deterministic(.init(
            hasGym: false, gymMinute: nil, events: [event],
            locations: [], prepSessions: []))

        let eventBlock = plan.blocks.first { $0.kind == "event" }
        XCTAssertNotNil(eventBlock, "the appointment is in the plan")
        XCTAssertEqual(eventBlock?.startTime, "14:00")
        XCTAssertEqual(eventBlock?.isAnchor, true)
        XCTAssertTrue(eventBlock?.note?.contains("commute NOT included") == true,
                      "offline honesty: no measured commute, say so")

        // Nothing else may overlap the event window.
        for b in plan.blocks where b.kind != "event" {
            guard let s = minutes(b.startTime), let e = minutes(b.endTime) else { continue }
            XCTAssertFalse(s < 15 * 60 && 14 * 60 < e,
                           "'\(b.title)' overlaps the dentist (\(b.startTime ?? "?")–\(b.endTime ?? "?"))")
        }
        XCTAssertTrue(plan.summary.contains("carved in"), "summary states the carve")
    }

    func testDisplacedBlocksAreReportedNotSilent() {
        // A midday event displaces whatever the scheduler had there.
        let event = DailyEvent(date: Date(), title: "Long lunch meeting",
                               startMinute: 11 * 60, endMinute: 14 * 60)
        let plan = PlanCoordinator.deterministic(.init(
            hasGym: false, gymMinute: nil, events: [event],
            locations: [], prepSessions: []))
        XCTAssertFalse(plan.dropped.isEmpty,
                       "three midday hours displace something, and it must be reported")
    }

    func testAllDayEventsDoNotCarve() {
        let allDay = DailyEvent(date: Date(), title: "Bali",
                                startMinute: 0, endMinute: 0, isAllDay: true)
        let plan = PlanCoordinator.deterministic(.init(
            hasGym: false, gymMinute: nil, events: [allDay],
            locations: [], prepSessions: []))
        XCTAssertNil(plan.blocks.first { $0.kind == "event" },
                     "all-day context events are not timed anchors")
        XCTAssertTrue(plan.dropped.isEmpty)
    }

    func testNoEventsMeansUnchangedBehavior() {
        let plan = PlanCoordinator.deterministic(.init(
            hasGym: true, gymMinute: 19 * 60, events: [],
            locations: [], prepSessions: []))
        XCTAssertFalse(plan.blocks.isEmpty)
        XCTAssertTrue(plan.dropped.isEmpty)
    }
}
