//
//  FitnessLogicTests.swift
//  JeevesTests
//
//  Pure-logic coverage for the fitness features: weightlifting tonnage, the
//  couch-to-5K distance helper + plan shape, and stretch-routine timing. All
//  deterministic — no store, no network.
//

import XCTest
@testable import Jeeves

final class FitnessLogicTests: XCTestCase {

    // MARK: - Tonnage

    func testWeightedTonnageIsRepsTimesLoad() {
        XCTAssertEqual(LiftMath.setTonnage(inputType: .weighted, reps: 5, weightKg: 100,
                                           bodyweightKg: 0, addedKg: 0), 500)
    }

    func testBodyweightTonnageCountsBodyMassPlusAdded() {
        // 5 pull-ups at 72kg bodyweight + 10kg belt = 5 × 82 = 410.
        XCTAssertEqual(LiftMath.setTonnage(inputType: .bodyweight, reps: 5, weightKg: 0,
                                           bodyweightKg: 72, addedKg: 10), 410)
    }

    func testIsometricContributesNoTonnage() {
        XCTAssertEqual(LiftMath.setTonnage(inputType: .isometric, reps: 0, weightKg: 0,
                                           bodyweightKg: 72, addedKg: 0), 0)
    }

    // MARK: - Run distance + plan shape

    func testRunDistanceSumsPaceOverTime() {
        // 7 km/h for 1h (7.0 km) + 5 km/h for 30 min (2.5 km) = 9.5 km.
        let segments = [RunSegment.run(3600, kmh: 7.0), RunSegment.walk(1800, kmh: 5.0)]
        XCTAssertEqual(RunSession.distanceKm(for: segments), 9.5, accuracy: 0.0001)
    }

    func testCouchTo5KIsSixteenFullWeeks() {
        XCTAssertEqual(RunProgram.totalWeeks, 16)
        XCTAssertEqual(RunProgram.weeks.count, 16, "the plan must be fully populated")
    }

    // MARK: - Stretch timing

    func testPerSideMovesCountTwiceInTotalTime() {
        let routine = StretchRoutine(name: "Test", subtitle: "unit", moves: [
            StretchMove("A", target: "x", holdSeconds: 30),
            StretchMove("B", target: "y", holdSeconds: 30, perSide: true),
        ])
        XCTAssertEqual(routine.totalSeconds, 90)   // 30 + 30×2
        XCTAssertEqual(routine.segmentCount, 3)    // A once, B twice
    }

    func testBuiltInCoolDownIsNonEmpty() {
        XCTAssertFalse(StretchRoutine.coolDown.moves.isEmpty)
        XCTAssertGreaterThan(StretchRoutine.coolDown.totalSeconds, 0)
    }
}
