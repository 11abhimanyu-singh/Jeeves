//
//  CheckInAutoFillTests.swift
//  JeevesTests
//
//  The check-in auto-derive layer: workouts tick the check-in on their own,
//  manual ticks add but can't remove, explicit rest survives a walk, and a
//  logged workout alone qualifies the day for the streak.
//

import XCTest
@testable import Jeeves

final class CheckInAutoFillTests: XCTestCase {

    private typealias Fact = CheckInAutoFill.WorkoutFact

    // MARK: Derivation

    func testLiftTicksWeightTraining() {
        let d = CheckInAutoFill.derive([Fact(type: .lift, durationMin: 47)])
        XCTAssertTrue(d.weightTraining)
        XCTAssertFalse(d.cardio)
    }

    func testWalkFillsCardioWithMinutesAndIncline() {
        let d = CheckInAutoFill.derive([Fact(type: .walk, durationMin: 32, incline: 4)])
        XCTAssertTrue(d.cardio)
        XCTAssertEqual(d.cardioType, "Inclined Walk")
        XCTAssertEqual(d.cardioDuration, 32)
        XCTAssertEqual(d.cardioIncline, 4)
    }

    func testRunBeatsWalkForCardioDetail() {
        let d = CheckInAutoFill.derive([
            Fact(type: .walk, durationMin: 30, incline: 4),
            Fact(type: .run, durationMin: 25),
        ])
        XCTAssertEqual(d.cardioType, "Running")
        XCTAssertEqual(d.cardioDuration, 25)
        // The walk's detail is still remembered (for rest-day suffixes).
        XCTAssertEqual(d.walkMinutes, 30)
    }

    func testLiveWorkoutContributesNothing() {
        let d = CheckInAutoFill.derive([Fact(type: .lift, finished: false, durationMin: 10)])
        XCTAssertFalse(d.weightTraining)
        XCTAssertFalse(d.hasAnything)
    }

    func testStretchLogTicksStretching() {
        let d = CheckInAutoFill.derive([], stretchCount: 1)
        XCTAssertTrue(d.stretching)
    }

    // MARK: Merge + day semantics

    func testWorkoutAloneQualifiesWithoutCheckIn() {
        let auto = CheckInAutoFill.derive([Fact(type: .lift, durationMin: 40)])
        let s = try! XCTUnwrap(CheckInAutoFill.mergedDay(auto: auto, manual: nil))
        XCTAssertTrue(s.qualifies, "a logged workout keeps the streak alive with no check-in tap")
        XCTAssertFalse(s.isRest)
        XCTAssertTrue(s.summary.contains("Weight"))
    }

    func testRestDaySurvivesAWalk() {
        let auto = CheckInAutoFill.derive([Fact(type: .walk, durationMin: 30, incline: 2)])
        let manual = CheckInAutoFill.ManualFacts(workedOut: false)
        let s = try! XCTUnwrap(CheckInAutoFill.mergedDay(auto: auto, manual: manual))
        XCTAssertTrue(s.isRest, "walks don't cancel an explicit rest day")
        XCTAssertFalse(s.qualifies)
        XCTAssertTrue(s.summary.contains("Rest day"))
        XCTAssertTrue(s.summary.contains("Walk 30min"), "the walk still shows: \(s.summary)")
    }

    func testTrainingOverridesRestMark() {
        let auto = CheckInAutoFill.derive([Fact(type: .lift, durationMin: 45)])
        let manual = CheckInAutoFill.ManualFacts(workedOut: false)
        let s = try! XCTUnwrap(CheckInAutoFill.mergedDay(auto: auto, manual: manual))
        XCTAssertFalse(s.isRest, "a logged lift overrides a stale rest mark")
        XCTAssertTrue(s.qualifies)
    }

    func testManualAddsToAuto() {
        let auto = CheckInAutoFill.derive([Fact(type: .lift)])
        let manual = CheckInAutoFill.ManualFacts(workedOut: true, mobility: true)
        let s = try! XCTUnwrap(CheckInAutoFill.mergedDay(auto: auto, manual: manual))
        XCTAssertTrue(s.summary.contains("Weight"))
        XCTAssertTrue(s.summary.contains("Mobility"), "manual mobility joins the auto weight tick")
    }

    func testAutoCardioDetailWinsOverManual() {
        let auto = CheckInAutoFill.derive([Fact(type: .walk, durationMin: 32, incline: 4)])
        let manual = CheckInAutoFill.ManualFacts(workedOut: true, cardio: true,
                                                 cardioType: "Inclined Walk",
                                                 cardioDuration: 30, cardioIncline: 3)
        let s = try! XCTUnwrap(CheckInAutoFill.mergedDay(auto: auto, manual: manual))
        XCTAssertTrue(s.summary.contains("32min"), "the workout's numbers win: \(s.summary)")
        XCTAssertTrue(s.summary.contains("4%"))
    }

    func testEmptyDayHasNoStatus() {
        XCTAssertNil(CheckInAutoFill.mergedDay(auto: CheckInAutoFill.derive([]), manual: nil))
    }

    func testPlainRestDay() {
        let s = try! XCTUnwrap(CheckInAutoFill.mergedDay(auto: CheckInAutoFill.derive([]),
                                                         manual: .init(workedOut: false)))
        XCTAssertTrue(s.isRest)
        XCTAssertEqual(s.summary, "Rest day")
    }
}
