//
//  CommuteRefreshTests.swift
//  JeevesTests
//
//  The live-refresh decision logic is pure, so it's fully unit-testable here:
//  which commute legs are due for a re-check, when a change is material, and
//  how the plan is rewritten. The execution (network + SwiftData) is exercised
//  by the opt-in live tests.
//

import XCTest
@testable import Jeeves

final class CommuteRefreshTests: XCTestCase {

    private func b(_ title: String, _ start: String, _ end: String, kind: String = "activity") -> GeneratedBlock {
        GeneratedBlock(title: title, startTime: start, endTime: end, note: nil, isAnchor: false, kind: kind)
    }
    private func event(_ title: String, _ start: Int, _ end: Int, address: String = "MLR Convention Centre, Bengaluru", from: LocationKind = .home) -> DailyEvent {
        DailyEvent(date: Date().startOfDay, title: title, startMinute: start, endMinute: end,
                   destinationAddress: address, outboundStart: from, source: .manual)
    }
    private func plan(_ blocks: [GeneratedBlock]) -> GeneratedPlan {
        GeneratedPlan(blocks: blocks, dropped: [], shrunk: [], summary: "", boundaryTime: nil)
    }
    private let home = SavedLocation(kind: .home, address: "Koramangala, Bengaluru")

    // MARK: legsDue

    func testCommuteBeforeEventWithinWindowIsDue() {
        let p = plan([b("Reading", "12:00", "13:15"),
                      b("Commute to Appt", "13:15", "14:00", kind: "commute"),
                      b("Appt", "14:00", "15:00", kind: "event")])
        let due = CommuteRefresh.legsDue(plan: p, events: [event("Appt", 14 * 60, 15 * 60)], locations: [home], nowMinute: 13 * 60)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.commuteTitle, "Commute to Appt")
        XCTAssertEqual(due.first?.destination, "MLR Convention Centre, Bengaluru")
        XCTAssertEqual(due.first?.origin, "Koramangala, Bengaluru")
        XCTAssertEqual(due.first?.anchorStartMinute, 14 * 60)
        XCTAssertEqual(due.first?.currentDepartMinute, 13 * 60 + 15)
    }

    func testCommuteOutsideWindowIsNotDue() {
        let p = plan([b("Commute to Appt", "13:15", "14:00", kind: "commute"),
                      b("Appt", "14:00", "15:00", kind: "event")])
        // now = 11:00 → departs in 135 min, beyond the 90-min window.
        XCTAssertTrue(CommuteRefresh.legsDue(plan: p, events: [event("Appt", 14 * 60, 15 * 60)], locations: [home], nowMinute: 11 * 60).isEmpty)
    }

    func testAlreadyDepartedCommuteIsNotDue() {
        let p = plan([b("Commute to Appt", "13:15", "14:00", kind: "commute"),
                      b("Appt", "14:00", "15:00", kind: "event")])
        XCTAssertTrue(CommuteRefresh.legsDue(plan: p, events: [event("Appt", 14 * 60, 15 * 60)], locations: [home], nowMinute: 13 * 60 + 30).isEmpty)
    }

    func testCommuteNotLeadingToEventIsNotDue() {
        // Commute to gym is followed by a gym block, not an event.
        let p = plan([b("Commute to gym", "13:15", "13:45", kind: "commute"),
                      b("Mobility", "13:45", "14:05", kind: "gym")])
        XCTAssertTrue(CommuteRefresh.legsDue(plan: p, events: [], locations: [home], nowMinute: 13 * 60).isEmpty)
    }

    func testDueRequiresAResolvableOriginAddress() {
        let p = plan([b("Commute to Appt", "13:15", "14:00", kind: "commute"),
                      b("Appt", "14:00", "15:00", kind: "event")])
        // No saved locations → no origin address → nothing to price.
        XCTAssertTrue(CommuteRefresh.legsDue(plan: p, events: [event("Appt", 14 * 60, 15 * 60)], locations: [], nowMinute: 13 * 60).isEmpty)
    }

    // MARK: revisedDeparture

    func testRevisedDepartureFlagsMaterialChange() {
        // Anchor 14:00, fresh drive 50 min → leave 13:10; was 13:15 → 5 min earlier, material.
        let r = CommuteRefresh.revisedDeparture(anchorStartMinute: 14 * 60, freshDurationMinutes: 50, currentDepartMinute: 13 * 60 + 15)
        XCTAssertEqual(r.departMinute, 13 * 60 + 10)
        XCTAssertTrue(r.changed)
    }

    func testRevisedDepartureIgnoresTinyWobble() {
        // Fresh drive 44 min → leave 13:16; was 13:15 → 1 min, immaterial.
        let r = CommuteRefresh.revisedDeparture(anchorStartMinute: 14 * 60, freshDurationMinutes: 44, currentDepartMinute: 13 * 60 + 15)
        XCTAssertFalse(r.changed)
    }

    // MARK: applyDeparture

    func testApplyDepartureRewritesCommuteAndTrimsPreviousBlock() {
        let p = plan([b("Reading", "12:00", "13:15"),
                      b("Commute to Appt", "13:15", "14:00", kind: "commute"),
                      b("Appt", "14:00", "15:00", kind: "event")])
        // Traffic worsened: now leave at 13:00.
        let updated = CommuteRefresh.applyDeparture(to: p, commuteTitle: "Commute to Appt", newDepartMinute: 13 * 60, anchorStartMinute: 14 * 60)
        let commute = updated.blocks.first { $0.kind == "commute" }
        XCTAssertEqual(commute?.startTime, "13:00")
        XCTAssertEqual(commute?.endTime, "14:00")
        let reading = updated.blocks.first { $0.title == "Reading" }
        XCTAssertEqual(reading?.endTime, "13:00", "the preceding block is trimmed so it doesn't overlap the earlier departure")
    }

    func testApplyDepartureLeavesUnrelatedBlocksIntact() {
        let p = plan([b("Reading", "12:00", "13:15"),
                      b("Commute to Appt", "13:15", "14:00", kind: "commute"),
                      b("Appt", "14:00", "15:00", kind: "event")])
        let updated = CommuteRefresh.applyDeparture(to: p, commuteTitle: "Commute to Appt", newDepartMinute: 13 * 60, anchorStartMinute: 14 * 60)
        XCTAssertEqual(updated.blocks.first { $0.kind == "event" }?.startTime, "14:00", "the event anchor is untouched")
        XCTAssertEqual(updated.blocks.count, p.blocks.count)
    }

    // MARK: nextDepartureMinute

    func testNextDepartureMinutePicksSoonestFutureEventCommute() {
        let p = plan([b("Commute to A", "10:00", "10:30", kind: "commute"),
                      b("A", "10:30", "11:00", kind: "event"),
                      b("Commute to B", "16:00", "16:30", kind: "commute"),
                      b("B", "16:30", "17:00", kind: "event")])
        let events = [event("A", 10 * 60 + 30, 11 * 60), event("B", 16 * 60 + 30, 17 * 60)]
        XCTAssertEqual(CommuteRefresh.nextDepartureMinute(plan: p, events: events, locations: [home], nowMinute: 9 * 60), 10 * 60)
        // After A has departed, B is next.
        XCTAssertEqual(CommuteRefresh.nextDepartureMinute(plan: p, events: events, locations: [home], nowMinute: 12 * 60), 16 * 60)
    }

    // MARK: notification copy

    func testCommuteUpdateBodyWording() {
        XCTAssertTrue(NotificationService.commuteUpdateBody(commuteTitle: "Commute to Appt", newDepartMinute: 13 * 60, earlierByMinutes: 15)
            .contains("leave by 13:00"))
        XCTAssertTrue(NotificationService.commuteUpdateBody(commuteTitle: "Commute to Appt", newDepartMinute: 13 * 60, earlierByMinutes: 15)
            .contains("15 min earlier"))
        XCTAssertTrue(NotificationService.commuteUpdateBody(commuteTitle: "Commute to Appt", newDepartMinute: 13 * 60 + 20, earlierByMinutes: -10)
            .localizedCaseInsensitiveContains("lighter"))
    }
}
