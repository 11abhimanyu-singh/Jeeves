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
}
