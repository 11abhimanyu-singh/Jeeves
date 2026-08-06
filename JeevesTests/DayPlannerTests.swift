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

    /// The morning belongs to whatever the ROUTINE puts first. A hardcoded
    /// "Interview prep — Reading" used to open every day at the day start, and
    /// it outranked a routine that had led with Chores for weeks.
    func testTheDayOpensWithWhateverTheRoutinePutsFirst() {
        let blocks = DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: [])
        let first = blocks.min { $0.startMinute < $1.startMinute }
        XCTAssertEqual(first?.title, Baseline.activities.first?.name,
                       "the first block is the routine's first activity, not a title frozen in DayPlanner")
        XCTAssertEqual(first?.startMinute, 8 * 60)
    }

    /// Reorder the routine and the morning reorders with it — the real proof,
    /// since asserting against the default list alone would still pass if the
    /// title were hardcoded to whatever happens to sit at the top of it.
    func testReorderingTheRoutineReordersTheMorning() {
        let routine = [
            BaselineActivity(name: "Job applications", durationMinutes: 45, tier: .important, note: nil),
            BaselineActivity(name: "Chores", durationMinutes: 40, tier: .flexible, note: nil),
        ]
        let blocks = DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: [],
                                         routine: routine)
        XCTAssertEqual(blocks.min { $0.startMinute < $1.startMinute }?.title, "Job applications")

        let flipped = DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: [],
                                          routine: routine.reversed())
        XCTAssertEqual(flipped.min { $0.startMinute < $1.startMinute }?.title, "Chores")
    }

    /// A day the user deliberately emptied stays empty. Filling the hours back
    /// in with "Discretionary time — suggested: Music" is still the planner
    /// deciding what the evening is for.
    func testAClearedDayIsNotHelpfullyRefilled() {
        let blocks = DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: [],
                                         routine: [], fillFreeTime: false)
        XCTAssertTrue(blocks.allSatisfy { $0.title != "Discretionary time" },
                      "an empty day is the answer, not a gap to fill")
        XCTAssertNotNil(block("Sleep", in: blocks), "the day still ends")
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

    /// Every day — rest or gym — ends with a fixed Sleep anchor at 11 PM, and
    /// no productive work is scheduled past the 20:30 boundary.
    func testEveryDayEndsWithSleepAtEleven() {
        for gym: Int? in [nil, 11 * 60, 17 * 60] {
            let blocks = DayPlanner.generate(gymMinute: gym, prepSessions: [], leisureLogs: [])
            let sleep = block("Sleep", in: blocks)
            XCTAssertNotNil(sleep, "gym \(String(describing: gym)): day should end with Sleep")
            XCTAssertEqual(sleep?.startMinute, DayPlanner.sleepMinute, "Sleep starts at 23:00")
            XCTAssertTrue(sleep?.isAnchor ?? false, "Sleep is a fixed anchor")
            XCTAssertEqual(blocks.map(\.startMinute).max(), sleep?.startMinute, "nothing starts after Sleep")
            // No productive work past 20:30 (wind-down/sleep may run later).
            let productive = Set(["Interview prep — Reading", "Job applications", "Reading habit", "Lunch", "Chore buffer", "Chores", "Photography"])
            for b in blocks where productive.contains(b.title) {
                XCTAssertLessThanOrEqual(b.endMinute, DayPlanner.dayEndMinute, "'\(b.title)' runs past 20:30")
            }
        }
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

    func testGymIsOneAnchorBlockAtTheEnteredTime() {
        let blocks = DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: [])
        XCTAssertEqual(block("Gym", in: blocks)?.startMinute, 11 * 60)
        XCTAssertEqual(block("Gym", in: blocks)?.durationMinutes, 125, "20 + 70 + 35, as one block")
        // 30 min drive + 10 min parking, worked backward. Nothing else runs
        // before the session now that it isn't split.
        XCTAssertEqual(block("Commute to gym", in: blocks)?.startMinute, 11 * 60 - 40)
        XCTAssertNil(block("Gym — Mobility", in: blocks), "the parts are logged in Fitness")
        XCTAssertNil(block("Gym — Cardio", in: blocks))
    }

    /// Switching a part off shortens the one block; the start doesn't move.
    func testDisablingAPartShortensTheBlockWithoutMovingIt() {
        let session = [(name: "Weightlifting", minutes: 70), (name: "Cardio", minutes: 35)]
        let blocks = DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: [],
                                         gymSession: session)
        XCTAssertEqual(block("Gym", in: blocks)?.startMinute, 11 * 60)
        XCTAssertEqual(block("Gym", in: blocks)?.durationMinutes, 105)
        XCTAssertEqual(block("Commute to gym", in: blocks)?.startMinute, 11 * 60 - 40)
    }

    func testOutboundGymCommuteCarriesTheParkingBufferAndTheWayHomeDoesNot() {
        let blocks = DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: [])
        XCTAssertEqual(block("Commute to gym", in: blocks)?.durationMinutes, 40)
        XCTAssertEqual(block("Commute home", in: blocks)?.durationMinutes, 30)
        XCTAssertEqual(block("Commute to gym", in: blocks)?.note,
                       "30 min drive + 10 min parking",
                       "the two parts stay legible instead of one inflated number")
    }

    func testGymDaysHaveNoOverlaps() {
        assertNoOverlaps(DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: []))
        assertNoOverlaps(DayPlanner.generate(gymMinute: 13 * 60, prepSessions: [], leisureLogs: []))
        assertNoOverlaps(DayPlanner.generate(gymMinute: 16 * 60, prepSessions: [], leisureLogs: []))
    }

    /// A gym entered impossibly early — before the fixed morning blocks can
    /// finish — must NOT emit a commute that starts before chores end. The gym
    /// slides to the first slot that fits instead of overlapping the morning.
    func testVeryEarlyGymProducesNoOverlaps() {
        for gym in [8 * 60, 8 * 60 + 30, 9 * 60, 10 * 60] {
            let blocks = DayPlanner.generate(gymMinute: gym, prepSessions: [], leisureLogs: [])
            assertNoOverlaps(blocks)
            let commute = block("Commute to gym", in: blocks)
            XCTAssertNotNil(commute, "gym \(gym): a gym day still has a commute")
        }
    }

    // MARK: what the offline packer may never emit
    //
    // The fallback ran on 4 of the 31 stored plan-days and produced, on 5 Aug
    // alone, three 10-minute Breathers, a 15-minute Slack, a 16-minute Free
    // time and Sleep 23:00 → 31:00. None of those are decisions; they are
    // arithmetic left over from trying to make an impossible day close.

    private func everyOfflineDay() -> [(label: String, blocks: [PlanBlock])] {
        [("rest day", DayPlanner.generate(gymMinute: nil, prepSessions: [], leisureLogs: [])),
         ("gym day", DayPlanner.generate(gymMinute: 11 * 60, prepSessions: [], leisureLogs: [])),
         ("late gym", DayPlanner.generate(gymMinute: 17 * 60, prepSessions: [], leisureLogs: []))]
    }

    func testTheOfflinePackerInventsNoFillerBlocks() {
        for (label, blocks) in everyOfflineDay() {
            for banned in ["Breather", "Slack", "Free time"] {
                XCTAssertFalse(blocks.contains { $0.title == banned },
                               "\(label) scheduled a '\(banned)' — leftover time is a gap, not an activity")
            }
        }
    }

    /// The floor bounds TRIMMING; it does not forbid short activities. A
    /// routine activity runs at the length the routine gave it, or trimmed no
    /// further than the floor, or not at all. Shower is a fixed 20 minutes and
    /// Discretionary time is honest empty time — neither is a remainder, and
    /// neither is in scope.
    func testARoutineActivityRunsAtItsOwnLengthOrNoShorterThanTheFloor() {
        var checked = 0
        for (label, blocks) in everyOfflineDay() {
            for b in blocks {
                guard let configured = Baseline.activities.first(where: { $0.name == b.title })?.durationMinutes
                else { continue }
                checked += 1
                XCTAssertTrue(
                    b.durationMinutes == configured || b.durationMinutes >= DayPlanner.minActivityMinutes,
                    "\(label): '\(b.title)' was cut from \(configured) to \(b.durationMinutes) min — below the floor it is leftovers, not the activity")
            }
        }
        XCTAssertGreaterThan(checked, 0, "a test that checked nothing has not passed")
    }

    /// The breather survives as a GAP. PlanRules measures the distance between
    /// consecutive prep blocks and ignores what sits between them, so removing
    /// the block must not start failing the rule it was built to satisfy.
    func testRemovingTheBreatherBlockDidNotBreakTheBreatherRule() {
        for (label, blocks) in everyOfflineDay() {
            let generated = blocks.map {
                GeneratedBlock(title: $0.title,
                               startTime: GeneratedBlock.hhmm($0.startMinute),
                               endTime: GeneratedBlock.hhmm($0.endMinute),
                               note: nil, isAnchor: $0.isAnchor,
                               kind: $0.isAnchor ? "anchor" : "activity")
            }
            XCTAssertEqual(PlanRules.prepBreatherViolations(generated), [],
                           "\(label) put two prep blocks closer than the breather allows")
        }
    }

    /// Sleep is 23:00 plus eight hours. That is 07:00 tomorrow, not "31:00" —
    /// a string that is not a time, which every offline plan in the store
    /// carried because the packer formatted 1860 minutes without wrapping.
    func testAnEightHourSleepFromElevenEndsAtSevenNotThirtyOne() {
        XCTAssertEqual(GeneratedBlock.hhmm(23 * 60 + 8 * 60), "07:00")
        XCTAssertEqual(GeneratedBlock.hhmm(24 * 60), "00:00")
        XCTAssertEqual(GeneratedBlock.hhmm(20 * 60 + 30), "20:30", "times inside the day are untouched")

        for (label, blocks) in everyOfflineDay() {
            for b in blocks {
                let end = GeneratedBlock.minutes(from: GeneratedBlock.hhmm(b.endMinute)) ?? -1
                XCTAssertTrue((0...(24 * 60)).contains(end),
                              "\(label): '\(b.title)' ends at \(GeneratedBlock.hhmm(b.endMinute)), which is not an hour of any clock")
            }
        }
    }

    // MARK: Practice-split weighting

    /// Neglect now decides ORDER, not duration. The old split was
    /// [45, 35, 25, 15], so the category you needed least always drew a
    /// quarter-hour — one of the 39 sub-half-hour blocks across the stored
    /// plans, scheduled because minutes were left rather than because fifteen
    /// minutes is a thing anyone can practise in. Slices are now equal and
    /// never below the floor; the most-practised category simply goes last.
    func testPracticeSplitPutsTheMostPractisedCategoryLastRatherThanStarvingIt() throws {
        let container = try ModelContainer(
            for: PrepSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let sessions = (0..<3).map { _ in
            PrepSession(date: Date(), category: .productSense, durationMinutes: 45)
        }
        sessions.forEach { container.mainContext.insert($0) }

        let blocks = DayPlanner.generate(gymMinute: nil, prepSessions: sessions, leisureLogs: [])
        let practiceBlocks = blocks
            .filter { $0.title.hasPrefix("Interview prep — ") && $0.title != "Interview prep — Reading" }
            .sorted { $0.startMinute < $1.startMinute }

        XCTAssertEqual(practiceBlocks.last?.title, "Interview prep — Product Sense",
                       "three sessions logged this week, so it is the one that can wait")
        for b in practiceBlocks {
            XCTAssertGreaterThanOrEqual(b.durationMinutes, DayPlanner.minActivityMinutes,
                                        "'\(b.title)' is \(b.durationMinutes) min — below the floor it is leftovers, not practice")
        }
        XCTAssertEqual(practiceBlocks.map(\.durationMinutes).reduce(0, +), 120,
                       "the row's own 120 minutes are all still spent, just in equal parts")
    }
}
