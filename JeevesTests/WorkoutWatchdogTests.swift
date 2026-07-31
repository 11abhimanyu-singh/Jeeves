//
//  WorkoutWatchdogTests.swift
//  JeevesTests
//
//  The stuck-live workout rule the owner asked for after the digest surfaced
//  two sessions the watch had started and nothing ever ended: nudge at two
//  hours, close at four. Auto-closing is a deliberate exception to
//  surface-never-heal, so these tests pin BOTH that it happens and that it
//  stays honest — no invented duration, and an event the digest can report.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class WorkoutWatchdogTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        let schema = Schema([Workout.self, LiftSession.self, LiftSet.self,
                             RunSession.self, AppEvent.self, CheckIn.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        container = try! ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func liveWorkout(startedHoursAgo hours: Double, in context: ModelContext) -> Workout {
        let started = Date().addingTimeInterval(-hours * 3600)
        let w = Workout(date: started, type: .lift, state: .live, source: .watch, title: "Lift")
        context.insert(w)
        try? context.save()
        return w
    }

    // MARK: The thresholds

    func testUnderTwoHoursIsLeftAlone() {
        let now = Date()
        XCTAssertEqual(WorkoutWatchdog.verdict(startedAt: now.addingTimeInterval(-3600), now: now),
                       .leaveAlone)
    }

    func testTwoHoursNudges() {
        let now = Date()
        XCTAssertEqual(WorkoutWatchdog.verdict(startedAt: now.addingTimeInterval(-2 * 3600), now: now),
                       .nudge)
        XCTAssertEqual(WorkoutWatchdog.verdict(startedAt: now.addingTimeInterval(-3.9 * 3600), now: now),
                       .nudge)
    }

    func testFourHoursCloses() {
        let now = Date()
        XCTAssertEqual(WorkoutWatchdog.verdict(startedAt: now.addingTimeInterval(-4 * 3600), now: now),
                       .close)
        XCTAssertEqual(WorkoutWatchdog.verdict(startedAt: now.addingTimeInterval(-40 * 3600), now: now),
                       .close, "a workout stuck for days still just closes")
    }

    // MARK: What the sweep actually does

    func testSweepClosesAStaleWorkoutWithoutInventingADuration() async {
        let context = container.mainContext
        let workout = liveWorkout(startedHoursAgo: 5, in: context)

        await WorkoutWatchdog.sweep(context: context, notify: false)

        XCTAssertEqual(workout.state, .needsDetail,
                       "closed — but to needsDetail, because the real end time is unknown")
        XCTAssertEqual(workout.durationMin, 0,
                       "it must NOT claim five hours of exercise it never measured")
    }

    func testAutoCloseIsLoggedSoTheDigestStillReportsIt() async {
        let context = container.mainContext
        _ = liveWorkout(startedHoursAgo: 6, in: context)

        await WorkoutWatchdog.sweep(context: context, notify: false)

        let events = (try? context.fetch(FetchDescriptor<AppEvent>())) ?? []
        let closed = events.filter { $0.kind == .workoutAutoClosed }
        XCTAssertEqual(closed.count, 1, "an automatic repair still has to be surfaced")
        XCTAssertTrue(closed.first?.detail.contains("unknown") ?? false,
                      "and the log must say the duration is unknown: \(closed.first?.detail ?? "")")
    }

    func testSweepLeavesAFreshWorkoutRunning() async {
        let context = container.mainContext
        let workout = liveWorkout(startedHoursAgo: 0.5, in: context)

        await WorkoutWatchdog.sweep(context: context, notify: false)

        XCTAssertEqual(workout.state, .live, "half an hour in is just a workout")
    }

    func testSweepIsIdempotent() async {
        let context = container.mainContext
        _ = liveWorkout(startedHoursAgo: 5, in: context)

        await WorkoutWatchdog.sweep(context: context, notify: false)
        await WorkoutWatchdog.sweep(context: context, notify: false)

        let closed = ((try? context.fetch(FetchDescriptor<AppEvent>())) ?? [])
            .filter { $0.kind == .workoutAutoClosed }
        XCTAssertEqual(closed.count, 1, "sweeping twice must not log twice")
    }

    func testAlreadyFinishedWorkoutsAreUntouched() async {
        let context = container.mainContext
        let done = Workout(date: Date().addingTimeInterval(-10 * 3600), type: .run,
                           state: .done, source: .watch, title: "Run", durationMin: 42)
        context.insert(done)
        try? context.save()

        await WorkoutWatchdog.sweep(context: context, notify: false)

        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(done.durationMin, 42)
    }

    // MARK: Closing from the notification

    func testCloseFromTheNudgeEndsItAndLogs() {
        let context = container.mainContext
        let workout = liveWorkout(startedHoursAgo: 2.5, in: context)

        WorkoutWatchdog.close(workoutID: workout.id, context: context)

        XCTAssertEqual(workout.state, .needsDetail)
        let events = ((try? context.fetch(FetchDescriptor<AppEvent>())) ?? [])
            .filter { $0.kind == .workoutAutoClosed }
        XCTAssertEqual(events.count, 1)
    }

    func testClosingAWorkoutThatIsNoLongerLiveDoesNothing() {
        let context = container.mainContext
        let workout = liveWorkout(startedHoursAgo: 2.5, in: context)
        workout.state = .done
        try? context.save()

        WorkoutWatchdog.close(workoutID: workout.id, context: context)

        XCTAssertEqual(workout.state, .done, "a stale banner must not reopen a closed decision")
        let events = ((try? context.fetch(FetchDescriptor<AppEvent>())) ?? [])
            .filter { $0.kind == .workoutAutoClosed }
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: Wording

    func testNudgeBodyReadsLikeAPerson() {
        XCTAssertTrue(WorkoutWatchdog.nudgeBody(title: "Lift", openMinutes: 135)
            .contains("2h 15m"))
        XCTAssertTrue(WorkoutWatchdog.nudgeBody(title: "Lift", openMinutes: 120)
            .contains("2h"))
        XCTAssertTrue(WorkoutWatchdog.nudgeBody(title: "", openMinutes: 125)
            .hasPrefix("Your workout"), "an untitled session still reads properly")
        XCTAssertTrue(WorkoutWatchdog.nudgeBody(title: "Lift", openMinutes: 125)
            .contains("4 hours"), "the nudge says what happens if they ignore it")
    }
}
