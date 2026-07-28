//
//  PlanEditLogicTests.swift
//  JeevesTests
//
//  The re-timing that backs hand-editing is pure: anchors stay pinned to their
//  clock times, movable blocks flow contiguously around them.
//

import XCTest
@testable import Jeeves

final class PlanEditLogicTests: XCTestCase {

    private func b(_ title: String, _ start: String, _ end: String, anchor: Bool = false, kind: String = "activity") -> GeneratedBlock {
        GeneratedBlock(title: title, startTime: start, endTime: end, note: nil, isAnchor: anchor, kind: kind)
    }

    func testMovableBlocksFlowContiguously() {
        // Two movable blocks; the second should butt against the first.
        let out = PlanEditLogic.retime([
            b("A", "08:00", "09:00"),   // 60 min
            b("B", "10:00", "10:30"),   // 30 min, but should snap to 09:00
        ])
        XCTAssertEqual(out[0].startTime, "08:00"); XCTAssertEqual(out[0].endTime, "09:00")
        XCTAssertEqual(out[1].startTime, "09:00"); XCTAssertEqual(out[1].endTime, "09:30")
    }

    func testAnchorStaysPinnedAndResetsCursor() {
        // A short movable block, then a pinned anchor at 14:00, then another
        // movable — which must resume after the anchor, not overlap it.
        let out = PlanEditLogic.retime([
            b("Reading", "08:00", "09:30"),
            b("Appt", "14:00", "15:00", anchor: true, kind: "event"),
            b("Chores", "09:30", "10:10"),   // 40 min → must start at 15:00
        ])
        XCTAssertEqual(out[1].startTime, "14:00", "anchor keeps its fixed time")
        XCTAssertEqual(out[1].endTime, "15:00")
        XCTAssertEqual(out[2].startTime, "15:00", "movable resumes after the anchor")
        XCTAssertEqual(out[2].endTime, "15:40")
    }

    func testLongMovableBeforeAnchorDoesNotOverlapIt() {
        // A movable block long enough to run past a later anchor's start must be
        // pushed to after the anchor's end, never placed overlapping it.
        let out = PlanEditLogic.retime([
            b("Deep work", "09:00", "12:00"),                        // 180-min movable
            b("Standup", "10:00", "10:30", anchor: true, kind: "event"),
        ])
        let anchor = out.first { $0.title == "Standup" }!
        let movable = out.first { $0.title == "Deep work" }!
        XCTAssertEqual(anchor.startTime, "10:00", "anchor stays pinned")
        let overlaps = (movable.startMinute! < anchor.endMinute!) && (movable.endMinute! > anchor.startMinute!)
        XCTAssertFalse(overlaps, "movable (\(movable.startTime)–\(movable.endTime)) overlaps the pinned anchor")
    }

    func testReorderThenRetimeReflectsNewOrder() {
        var blocks = [b("A", "08:00", "08:30"), b("B", "08:30", "09:30")]  // 30, 60
        blocks.swapAt(0, 1)                                                 // B then A
        let out = PlanEditLogic.retime(blocks)
        XCTAssertEqual(out[0].title, "B"); XCTAssertEqual(out[0].startTime, "08:00"); XCTAssertEqual(out[0].endTime, "09:00")
        XCTAssertEqual(out[1].title, "A"); XCTAssertEqual(out[1].startTime, "09:00"); XCTAssertEqual(out[1].endTime, "09:30")
    }

    func testDurationEditCascadesDownstream() {
        var blocks = [b("A", "08:00", "09:00"), b("B", "09:00", "09:30")]
        blocks[0] = blocks[0].withDuration(120)     // A grows 60→120
        let out = PlanEditLogic.retime(blocks)
        XCTAssertEqual(out[0].endTime, "10:00")
        XCTAssertEqual(out[1].startTime, "10:00", "B shifts later after A grows")
        XCTAssertEqual(out[1].endTime, "10:30")
    }

    func testDurationHelperKeepsStart() {
        let block = b("X", "08:00", "08:30").withDuration(45)
        XCTAssertEqual(block.startTime, "08:00")
        XCTAssertEqual(block.endTime, "08:45")
        XCTAssertEqual(block.durationMinutes, 45)
    }

    func testEditedUpdatesTitleNoteAndDuration() {
        let edited = b("Commute to gym", "18:00", "18:30", kind: "commute")
            .edited(title: "Commute to studio", note: "Home → Downtown studio", durationMinutes: 45)
        XCTAssertEqual(edited.title, "Commute to studio")
        XCTAssertEqual(edited.note, "Home → Downtown studio")
        XCTAssertEqual(edited.durationMinutes, 45)
        XCTAssertEqual(edited.kind, "commute", "kind is preserved")
        XCTAssertEqual(edited.startTime, "18:00", "start is kept; retime handles the clock")
    }

    func testEditedBlankNoteBecomesNil() {
        let edited = b("Chores", "10:00", "10:40").edited(title: "Chores", note: "   ", durationMinutes: 40)
        XCTAssertNil(edited.note)
    }

    // MARK: Full edit session (mirrors what the editor UI does end-to-end)

    /// QA for the plan-editor feature: a real editing session — reorder two
    /// movable blocks, then open one and change its title / location / length —
    /// must produce a correct, contiguous, anchor-respecting plan, exactly as
    /// the editor commits it.
    func testFullEditSessionReorderThenEditDetail() {
        var blocks = [
            b("Interview prep — Reading", "08:00", "09:30", anchor: true), // pinned
            b("Job applications", "09:30", "10:45"),                       // 75
            b("Chores", "10:45", "11:25"),                                 // 40
            b("Lunch", "13:00", "13:30", kind: "lunch"),                   // movable, 30
            b("Weightlifting", "19:00", "20:10", anchor: true, kind: "gym"),// pinned
        ]

        // 1. Reorder: move Chores (index 2) above Job applications (index 1) —
        //    the same op onMove performs — then re-time.
        blocks.move(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        blocks = PlanEditLogic.retime(blocks)

        // 2. Edit a block's detail: grow Job applications to 90 and relabel it —
        //    the same op BlockDetailEditor performs — then re-time.
        let jobIndex = blocks.firstIndex { $0.title == "Job applications" }!
        blocks[jobIndex] = blocks[jobIndex].edited(title: "Applications + outreach",
                                                   note: "LinkedIn + referrals", durationMinutes: 90)
        blocks = PlanEditLogic.retime(blocks)

        // 3. Save re-times once more (idempotent) — assert the committed result.
        let final = PlanEditLogic.retime(blocks)

        // Order reflects the reorder: Reading, Chores, Applications, Lunch, gym.
        XCTAssertEqual(final.map(\.title),
                       ["Interview prep — Reading", "Chores", "Applications + outreach", "Lunch", "Weightlifting"])
        // Anchors stayed pinned to their clock times.
        XCTAssertEqual(final[0].startTime, "08:00"); XCTAssertEqual(final[0].endTime, "09:30")
        XCTAssertEqual(final[4].startTime, "19:00"); XCTAssertEqual(final[4].endTime, "20:10")
        // Movable blocks flow contiguously from the day start.
        XCTAssertEqual(final[1].startTime, "09:30"); XCTAssertEqual(final[1].endTime, "10:10") // Chores 40
        XCTAssertEqual(final[2].startTime, "10:10"); XCTAssertEqual(final[2].endTime, "11:40") // Apps 90
        XCTAssertEqual(final[3].startTime, "11:40"); XCTAssertEqual(final[3].endTime, "12:10") // Lunch 30
        // The detail edit stuck.
        XCTAssertEqual(final[2].note, "LinkedIn + referrals")
        XCTAssertEqual(final[2].durationMinutes, 90)
        // No movable block overlaps the next.
        for (a, c) in zip(final, final.dropFirst()) where !c.isAnchor {
            XCTAssertLessThanOrEqual(a.endMinute ?? 0, c.startMinute ?? 0, "\(c.title) overlaps \(a.title)")
        }
    }
}
