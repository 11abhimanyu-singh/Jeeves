//
//  DayPlannerTests.swift
//  JeevesTests
//
//  Guards the scheduling engine's invariants — the rules that are easy to
//  silently break because nothing in the UI screams when they're violated:
//  lunch's 2:30 PM start deadline, Photography anchored at end of day, the
//  gym block anchored on the entered weights time, and the neglect-weighted
//  practice split.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class DayPlannerTests: XCTestCase {

    private func block(_ title: String, in blocks: [PlanBlock]) -> PlanBlock? {
        blocks.first { $0.title == title }
    }

    private func assertNoOverlaps(_ blocks: [PlanBlock], file: StaticString = #filePath, line: UInt = #line) {
        let sorted = blocks.sorted { $0.startMinute < $1.startMinute }
        for (prev, next) in zip(sorted, sorted.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                next.startMinute, prev.endMinute,
                "'\(next.title)' (starts \(DayPlanner.label(for: next.startMinute))) overlaps '\(prev.title)' (ends \(DayPlanner.label(for: prev.endMinute)))",
                file: file, line: line
            )
        }
    }

    // MARK: Rest day

    func testRestDayStartsWithInterviewReadingAtEight() {
        let blocks = DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: [])
        let first = blocks.min { $0.startMinute < $1.startMinute }
        XCTAssertEqual(first?.title, "Interview prep — Reading")
        XCTAssertEqual(first?.startMinute, 8 * 60)
    }

    func testRestDayLunchStartsByDeadline() {
        let blocks = DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: [])
        let lunch = block("Lunch", in: blocks)
        XCTAssertNotNil(lunch, "Rest day plan must include Lunch")
        XCTAssertLessThanOrEqual(lunch!.startMinute, DayPlanner.lunchDeadlineMinute)
    }

    func testRestDayPlacesPhotographyAsFlexible() {
        // Photography is a flexible activity now — present on a light day, and
        // NOT pinned to the end (it's no longer a fixed 20:00–20:30 anchor).
        let blocks = DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: [])
        let photo = block("Photography", in: blocks)
        XCTAssertNotNil(photo, "a rest day has room for Photography")
        XCTAssertFalse(photo?.isAnchor ?? true, "Photography is flexible, not an anchor")
    }

    func testRestDayHasNoOverlaps() {
        assertNoOverlaps(DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: []))
    }

    // MARK: Shower rule — morning shower on a second-half gym day

    func testFirstHalfGymHasOnlyPostGymShower() {
        let blocks = DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: [])
        XCTAssertEqual(blocks.filter { $0.title == "Shower" }.count, 1, "morning gym → one (post-gym) shower")
    }

    func testSecondHalfGymAddsMorningShower() {
        let blocks = DayPlanner.generate(gymMinute: 17 * 60, prepSessions: [], leisureLogs: [])
        let showers = blocks.filter { $0.title == "Shower" }
        XCTAssertEqual(showers.count, 2, "evening gym → morning shower + post-gym shower")
        XCTAssertTrue(showers.contains { $0.startMinute < 12 * 60 }, "one shower should be in the morning")
        assertNoOverlaps(blocks)
    }

    /// A leftover gap should never become a nonsensical tiny "Discretionary
    /// time" block — better to drop it and leave the gap. Sweep the whole range
    /// of gym times (plus rest day) to guard the floor.
    func testNoTinyDiscretionaryBlockAcrossGymTimes() {
        var gymTimes: [Int?] = [nil]
        for m in stride(from: 8 * 60, through: 18 * 60, by: 15) { gymTimes.append(m) }
        for gym in gymTimes {
            let blocks = DayPlanner.generate(gymMinute: gym, prepSessions: [], leisureLogs: [])
            for b in blocks where b.title == "Discretionary time" {
                XCTAssertGreaterThanOrEqual(
                    b.durationMinutes, DayPlanner.minDiscretionaryMinutes,
                    "gym \(String(describing: gym)): \(b.durationMinutes)-min discretionary block should have been dropped")
            }
        }
    }

    // MARK: Gym days — the lunch deadline under pressure

    /// Gym at 11:00 leaves zero pre-gym room, so everything overflows to
    /// after the gym. Lunch must still jump that post-gym queue to start by
    /// the 2:30 PM deadline instead of trailing 3h of other blocks.
    func testEarlyGymLunchStillStartsByDeadline() {
        let blocks = DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: [])
        let lunch = block("Lunch", in: blocks)
        XCTAssertNotNil(lunch)
        XCTAssertLessThanOrEqual(
            lunch!.startMinute, DayPlanner.lunchDeadlineMinute,
            "Lunch starts at \(DayPlanner.label(for: lunch!.startMinute)) — past the deadline"
        )
    }

    /// Gym at 1:00 PM: there IS pre-gym room, but seating Job applications
    /// first would leave too little of it for Lunch — and post-gym doesn't
    /// resume until after the deadline. Lunch must be seated pre-gym.
    func testMiddayGymLunchStillStartsByDeadline() {
        let blocks = DayPlanner.generate(gymMinute: 13 * 60, prepSessions: [], leisureLogs: [])
        let lunch = block("Lunch", in: blocks)
        XCTAssertNotNil(lunch)
        XCTAssertLessThanOrEqual(
            lunch!.startMinute, DayPlanner.lunchDeadlineMinute,
            "Lunch starts at \(DayPlanner.label(for: lunch!.startMinute)) — past the deadline"
        )
    }

    func testGymBlockAnchorsWeightsAtEnteredTime() {
        let blocks = DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: [])
        XCTAssertEqual(block("Weightlifting", in: blocks)?.startMinute, 11 * 60)
        XCTAssertEqual(block("Commute to gym", in: blocks)?.startMinute, 11 * 60 - 50)
        XCTAssertEqual(block("Mobility", in: blocks)?.startMinute, 11 * 60 - 20)
        XCTAssertEqual(block("Cardio", in: blocks)?.startMinute, 11 * 60 + 70)
    }

    func testGymDaysHaveNoOverlaps() {
        assertNoOverlaps(DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: []))
        assertNoOverlaps(DayPlanner.generate(gymMinute: 13 * 60, prepSessions: [], leisureLogs: []))
        assertNoOverlaps(DayPlanner.generate(gymMinute: 16 * 60, prepSessions: [], leisureLogs: []))
    }

    // MARK: Practice-split weighting

    /// The category with the most sessions logged this week must get the
    /// smallest slice of the 120-minute practice block.
    func testPracticeSplitGivesLeastTimeToMostPracticedCategory() throws {
        let container = try ModelContainer(
            for: PrepSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let sessions = (0..<3).map { _ in
            PrepSession(date: Date(), category: .productSense, durationMinutes: 45)
        }
        sessions.forEach { container.mainContext.insert($0) }

        let blocks = DayPlanner.generate(gymMinute: nil, prepSessions: sessions, leisureLogs: [])
        let productSense = block("Interview prep — Product Sense", in: blocks)
        XCTAssertNotNil(productSense)
        XCTAssertEqual(productSense!.durationMinutes, 15, "Most-practiced category should get the smallest (15-min) slice")

        let practiceBlocks = blocks.filter { $0.title.hasPrefix("Interview prep — ") && $0.title != "Interview prep — Reading" }
        XCTAssertEqual(practiceBlocks.map(\.durationMinutes).reduce(0, +), 120, "Practice slices must total 120 minutes")
    }
}
