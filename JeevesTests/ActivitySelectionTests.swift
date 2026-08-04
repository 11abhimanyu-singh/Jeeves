//
//  ActivitySelectionTests.swift
//  JeevesTests
//
//  The three states, and why there have to be three.
//
//  "Cancel all activities today and keep the full day free" cleared the gym,
//  correctly reported that no events remained, and then watched the planner
//  refill the day from the routine. The missing idea was not a filter — it was
//  the difference between a day nobody has chosen for and a day chosen to be
//  empty. Two states cannot tell those apart, and the fallback that rescues an
//  unseeded store is exactly what refills a deliberately emptied one.
//

import XCTest
@testable import Jeeves

final class ActivitySelectionTests: XCTestCase {

    private func row(_ name: String, _ minutes: Int = 30, order: Int,
                     enabled: Bool = true, group: RoutineGroup = .none) -> RoutineActivity {
        RoutineActivity(name: name, durationMinutes: minutes, tier: .important,
                        note: nil, enabled: enabled, sortOrder: order, group: group)
    }

    private var routine: [RoutineActivity] {
        [row("Chores", 40, order: 0),
         row("Reading", 90, order: 1, group: .interviewPrep),
         row("Job applications", 75, order: 2),
         row("Mobility", 20, order: 3, group: .gym)]
    }

    // MARK: the three states

    func testNoChoiceMeansTheWholeRoutine() {
        let out = Baseline.routine(from: routine, selection: .routine)
        XCTAssertEqual(out.map(\.name),
                       ["Chores", "Interview prep — Reading", "Job applications"],
                       "gym parts are placed with the gym anchor, never filled like activities")
    }

    func testAChoiceNarrowsTheDayWithoutTouchingTheRoutine() {
        let out = Baseline.routine(from: routine,
                                   selection: .only(["Chores", "Interview prep — Reading"]))
        XCTAssertEqual(out.map(\.name), ["Chores", "Interview prep — Reading"])
        XCTAssertTrue(routine.allSatisfy(\.enabled), "the routine itself is untouched")
    }

    /// The bug, in one assertion. An empty result falls back to the built-in
    /// defaults so an unseeded store still gets planned — and that fallback is
    /// what handed a cleared day straight back to the planner.
    func testADeliberatelyEmptiedDayStaysEmpty() {
        let cleared = Baseline.routine(from: routine, selection: .only([]))
        XCTAssertTrue(cleared.isEmpty, "the day the user cleared must not refill from defaults")

        let unseeded = Baseline.routine(from: [], selection: .routine)
        XCTAssertFalse(unseeded.isEmpty, "an unseeded store still gets the built-in routine")
    }

    func testOnlyAnExplicitChoiceIsABlankDay() {
        XCTAssertTrue(ActivitySelection.only([]).isBlankDay)
        XCTAssertFalse(ActivitySelection.routine.isBlankDay,
                       "an unchosen day is not an empty one")
        XCTAssertFalse(ActivitySelection.only(["Chores"]).isBlankDay)
    }

    func testASwitchedOffRoutineRowStaysOffEvenIfTicked() {
        let rows = [row("Chores", 40, order: 0, enabled: false),
                    row("Job applications", 75, order: 1)]
        let out = Baseline.routine(from: rows, selection: .only(["Chores", "Job applications"]))
        XCTAssertEqual(out.map(\.name), ["Job applications"],
                       "the routine's own switch still outranks a day's pick")
    }

    // MARK: round-tripping through the store's JSON

    func testTheEmptyChoiceSurvivesEncoding() {
        let state = DailyPlanState(date: Date().startOfDay, hasGymToday: false, gymMinute: nil)
        XCTAssertEqual(state.activitySelection, .routine, "nothing chosen yet")

        state.activitySelection = .only([])
        XCTAssertNotNil(state.activitySelectionJSON,
                        "'[]' has to persist — dropping it to nil is the day refilling itself")
        XCTAssertEqual(state.activitySelection, .only([]))

        state.activitySelection = .only(["Chores"])
        XCTAssertEqual(state.activitySelection, .only(["Chores"]))

        state.activitySelection = .routine
        XCTAssertNil(state.activitySelectionJSON)
    }

    // MARK: naming an activity the way a person would

    /// plannerName joins group to child with an em dash nobody types, so a
    /// bare `contains` never matched the single most likely phrase.
    func testAPersonsWordsMatchTheStoredName() {
        for phrase in ["interview prep reading", "Interview Prep Reading",
                       "reading", "interview prep"] {
            XCTAssertTrue(
                JeevesChatService.routineMatches(name: "Reading",
                                                 plannerName: "Interview prep — Reading",
                                                 query: phrase),
                "\"\(phrase)\" should name Interview prep — Reading")
        }
    }

    func testAGroupPhraseNamesEveryChild() {
        let children = ["Reading", "Product Sense", "Behavioral"]
        for child in children {
            XCTAssertTrue(
                JeevesChatService.routineMatches(name: child,
                                                 plannerName: "Interview prep — \(child)",
                                                 query: "interview prep"))
        }
    }

    func testAnUnrelatedPhraseMatchesNothing() {
        XCTAssertFalse(JeevesChatService.routineMatches(
            name: "Reading", plannerName: "Interview prep — Reading", query: "gym"))
        XCTAssertFalse(JeevesChatService.routineMatches(
            name: "Chores", plannerName: "Chores", query: "   "))
    }

    /// The reading HABIT is the library; prep reading is the interview. Two
    /// different activities that a substring match happily conflates.
    func testTheReadingHabitIsNotPrepReading() {
        XCTAssertFalse(JeevesChatService.routineMatches(
            name: "Reading habit", plannerName: "Reading habit",
            query: "interview prep reading"))
    }
}

/// The plan can go out of date without anything noticing.
///
/// Five tools move something the day was planned from. Only one rebuilt the
/// day. The rest left a plan on screen that disagreed with the events listed
/// directly above it — and left its notifications armed, so a cancelled
/// appointment still pushed "time to leave".
final class StalePlanMarkerTests: XCTestCase {

    private func state(withPlan: Bool) -> DailyPlanState {
        let s = DailyPlanState(date: Date().startOfDay, hasGymToday: false, gymMinute: nil)
        if withPlan {
            s.storePlan(GeneratedPlan(blocks: [], dropped: [], shrunk: [],
                                      summary: "x", boundaryTime: nil), isOffline: false)
        }
        return s
    }

    func testAPlannedDayGoesStaleWhenAnInputMoves() {
        let s = state(withPlan: true)
        XCTAssertFalse(s.isPlanStale, "a freshly built plan is current")
        s.markPlanStale("an event was cancelled")
        XCTAssertTrue(s.isPlanStale)
        XCTAssertEqual(s.planStaleReason, "an event was cancelled")
    }

    /// A day with no plan has nothing to invalidate — marking it would put a
    /// "this plan is out of date" banner over a day that was never planned.
    func testAnUnplannedDayIsNeverStale() {
        let s = state(withPlan: false)
        s.markPlanStale("an event was added")
        XCTAssertFalse(s.isPlanStale)
        XCTAssertNil(s.planStaleSince, "nothing to invalidate, nothing recorded")
    }

    /// The user needs to know what STARTED the drift, not the last thing to
    /// touch it — three edits in a row shouldn't rewrite the explanation.
    func testTheFirstReasonWins() {
        let s = state(withPlan: true)
        s.markPlanStale("an event was cancelled")
        let first = s.planStaleSince
        s.markPlanStale("the gym moved")
        XCTAssertEqual(s.planStaleReason, "an event was cancelled")
        XCTAssertEqual(s.planStaleSince, first, "the clock doesn't restart either")
    }

    func testRebuildingTheDayClearsIt() {
        let s = state(withPlan: true)
        s.markPlanStale("the gym moved")
        // What PlanCoordinator.commit does after storing a fresh plan.
        s.storePlan(GeneratedPlan(blocks: [], dropped: [], shrunk: [],
                                  summary: "rebuilt", boundaryTime: nil), isOffline: false)
        s.planStaleSince = nil
        s.planStaleReason = nil
        XCTAssertFalse(s.isPlanStale)
    }
}
