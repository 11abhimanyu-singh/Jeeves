//
//  NotificationServiceTests.swift
//  JeevesTests
//
//  The reminder scheduling itself hits the system notification center (not
//  unit-testable), but the decision logic — which blocks get a reminder and
//  what it says — is pure and worth guarding.
//

import XCTest
@testable import Jeeves

final class NotificationServiceTests: XCTestCase {

    private func block(_ kind: String, isAnchor: Bool, title: String = "X") -> GeneratedBlock {
        GeneratedBlock(title: title, startTime: "09:00", endTime: "09:30", note: nil, isAnchor: isAnchor, kind: kind)
    }

    func testAnchorsAndKeyKindsGetReminders() {
        XCTAssertTrue(NotificationService.shouldRemind(block("event", isAnchor: true)))
        XCTAssertTrue(NotificationService.shouldRemind(block("gym", isAnchor: true)))
        XCTAssertTrue(NotificationService.shouldRemind(block("commute", isAnchor: false)))  // departures matter even if not anchors
        XCTAssertTrue(NotificationService.shouldRemind(block("activity", isAnchor: true)))   // e.g. morning focus reading
    }

    func testFillerBlocksDoNotGetReminders() {
        XCTAssertFalse(NotificationService.shouldRemind(block("free", isAnchor: false)))
        XCTAssertFalse(NotificationService.shouldRemind(block("activity", isAnchor: false)))
        XCTAssertFalse(NotificationService.shouldRemind(block("lunch", isAnchor: false)))
    }

    func testReminderBodyWording() {
        XCTAssertEqual(NotificationService.reminderBody(for: block("commute", isAnchor: false, title: "Commute to gym")),
                       "Time to leave — Commute to gym")
        XCTAssertEqual(NotificationService.reminderBody(for: block("event", isAnchor: true, title: "Baithak")),
                       "In 15 min: Baithak at 09:00")
        XCTAssertEqual(NotificationService.reminderBody(for: block("gym", isAnchor: true, title: "Weightlifting")),
                       "Weightlifting")
    }

    func testEventsAndSleepRemindFifteenMinutesEarly() {
        XCTAssertEqual(NotificationService.leadMinutes(for: block("event", isAnchor: true)), 15)
        XCTAssertEqual(NotificationService.leadMinutes(for: block("sleep", isAnchor: true)), 15)
        // Everything else reminds right at its start time.
        XCTAssertEqual(NotificationService.leadMinutes(for: block("commute", isAnchor: false)), 0)
        XCTAssertEqual(NotificationService.leadMinutes(for: block("gym", isAnchor: true)), 0)
    }

    func testSleepGetsAReminder() {
        XCTAssertTrue(NotificationService.shouldRemind(block("sleep", isAnchor: true)))
        XCTAssertEqual(NotificationService.reminderBody(for: block("sleep", isAnchor: true, title: "Sleep")),
                       "Wind down — bedtime in 15 min")
    }

    func testPlanReadyBodyDistinguishesOffline() {
        XCTAssertEqual(NotificationService.planReadyBody(isOffline: false),
                       "Jeeves finished planning your day — tap to view it.")
        XCTAssertTrue(NotificationService.planReadyBody(isOffline: true).localizedCaseInsensitiveContains("offline"),
                      "an offline plan should say so in the completion banner")
    }
}
