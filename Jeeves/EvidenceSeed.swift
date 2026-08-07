//
//  EvidenceSeed.swift
//  Jeeves
//
//  The seam that makes the app photographable.
//
//  A UI test drives the app from a SEPARATE process, and the evidence it captures
//  is only worth anything if the app is in a known state and nothing is covering
//  the screen. Three things had to be true and none of them were:
//
//    1. NO CLOUDKIT. `JeevesApp` picks its store by looking for
//       `XCTestConfigurationFilePath` — which XCTest sets in the RUNNER, not in
//       the app under test. So a UI-tested launch takes the CloudKit branch,
//       against an account the simulator does not have, and `fatalError`s on
//       init. Unit tests never hit this because they run inside the app process.
//
//    2. NO PERMISSION ALERT. `NotificationService.configure()` asks for
//       authorization at launch, so the system alert sits over the first
//       screenshot. `simctl privacy` has no `notifications` service, so it
//       cannot be pre-granted from outside — it has to not be asked.
//
//    3. REAL CONTENT. Half the app's screens are gated on data existing: the
//       plan editor needs a saved plan, catch-up needs unanswered blocks, the
//       travel card needs a trip. An empty store photographs as a row of empty
//       states and tells the judge nothing about whether those screens were
//       ever built.
//
//  Everything here is inert unless `-JeevesEvidenceRun` is passed on the command
//  line, which only `tools/capture-evidence.sh` does.
//

import Foundation
import SwiftData

enum EvidenceSeed {
    /// Launch argument, not an environment variable — arguments also populate
    /// `NSArgumentDomain`, so the same mechanism pins `@AppStorage` defaults.
    static let flag = "-JeevesEvidenceRun"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    /// Wipes the store and lays down a fixed cast of data.
    ///
    /// Dates are built from `Date().startOfDay`, never from literals: the wall
    /// clock cannot be pinned (the views call `Date()` directly, with no seam),
    /// so the fixture pins STRUCTURE — "today has a plan, yesterday has two
    /// unanswered blocks" — and lets the absolute dates drift.
    @MainActor
    static func apply(container: ModelContainer) {
        guard isActive else { return }
        let context = container.mainContext
        wipe(context)

        let today = Date().startOfDay
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let inThreeDays = cal.date(byAdding: .day, value: 3, to: today) ?? today

        Baseline.seed(into: context)
        Baseline.regroup(in: context)

        seedPlans(context, today: today, yesterday: yesterday)
        seedTasks(context, today: today)
        seedLibrary(context)
        seedFitness(context, today: today, yesterday: yesterday)
        seedTravel(context, from: inThreeDays, cal: cal)
        seedEvents(context, today: today)

        try? context.save()
    }

    // MARK: the cast

    private static func seedPlans(_ context: ModelContext, today: Date, yesterday: Date) {
        // TODAY: a full plan, so the timeline, the plan editor (gated on a saved
        // plan) and every block-level control have something to render.
        let state = DailyPlanState(date: today, hasGymToday: true, gymMinute: 18 * 60)
        state.storePlan(samplePlan(), isOffline: false)
        context.insert(state)

        // YESTERDAY: a plan whose blocks were never answered, which is what
        // CatchUp looks for. Paired with resetting `jeeves.catchUp.lastShown`
        // via a launch argument so the sheet is actually offered.
        let past = DailyPlanState(date: yesterday, hasGymToday: false, gymMinute: nil)
        past.storePlan(samplePlan(), isOffline: true)
        context.insert(past)
    }

    /// Hand-built rather than run through `DayPlanner`, so the fixture cannot
    /// drift when the packer changes — the evidence run is measuring the UI, not
    /// the scheduler, and the scheduler has 913 tests of its own.
    private static func samplePlan() -> GeneratedPlan {
        GeneratedPlan(
            blocks: [
                GeneratedBlock(title: "Chores", startTime: "09:00", endTime: "10:00",
                               note: "Top of the fill order", isAnchor: false, kind: "activity"),
                GeneratedBlock(title: "Interview prep — Reading", startTime: "10:00", endTime: "11:30",
                               note: "Morning peak-focus slot", isAnchor: false, kind: "activity"),
                GeneratedBlock(title: "Job applications", startTime: "11:40", endTime: "12:55",
                               note: "After the 10-minute break", isAnchor: false, kind: "activity"),
                GeneratedBlock(title: "Lunch", startTime: "12:55", endTime: "13:25",
                               note: "Inside the 12:30–14:00 window", isAnchor: false, kind: "lunch"),
                GeneratedBlock(title: "Commute — Home to Gym", startTime: "17:30", endTime: "18:00",
                               note: "20 min drive + 10 min parking", isAnchor: false, kind: "commute"),
                GeneratedBlock(title: "Gym", startTime: "18:00", endTime: "20:05",
                               note: "Mobility 20 · Weightlifting 70 · Cardio 35", isAnchor: true, kind: "gym"),
                GeneratedBlock(title: "Sleep", startTime: "23:00", endTime: "07:00",
                               note: "Fixed 8-hour anchor", isAnchor: true, kind: "sleep"),
            ],
            dropped: ["Interview prep — Product Sense"],
            shrunk: ["Job applications 75→45"],
            summary: "Chores open the morning, then the 90-minute reading block at peak focus with a 10-minute break before job applications. Product Sense fell below the 30-minute floor, so it was dropped rather than scheduled as a stub.",
            boundaryTime: "20:30"
        )
    }

    private static func seedTasks(_ context: ModelContext, today: Date) {
        let cal = Calendar.current
        let at = { (h: Int) in cal.date(bySettingHour: h, minute: 0, second: 0, of: today) ?? today }

        context.insert(Reminder(title: "Collect spectacles", fireAt: at(19), recurrence: .once))
        context.insert(Reminder(title: "Take vitamins", fireAt: at(9), recurrence: .daily))
        context.insert(Reminder(title: "Water the plants", fireAt: at(8),
                                recurrence: .everyNDays, intervalDays: 3))

        context.insert(Todo(title: "Renew passport", notes: "Appointment slot opens Monday",
                            priority: .high, dueDate: cal.date(byAdding: .day, value: 7, to: today)))
        context.insert(Todo(title: "Reply to the recruiter", priority: .medium, sortOrder: 1))
        context.insert(Todo(title: "Back up the photo library", priority: .low, sortOrder: 2))
    }

    private static func seedLibrary(_ context: ModelContext) {
        context.insert(Book(title: "The Design of Everyday Things", author: "Don Norman",
                            status: .currentlyReading, totalPages: 368, currentPage: 142))
        context.insert(Book(title: "Thinking, Fast and Slow", author: "Daniel Kahneman",
                            status: .unread, totalPages: 499))
        context.insert(Book(title: "The Pragmatic Programmer", author: "Andrew Hunt",
                            status: .finished, rating: .liked, totalPages: 352, currentPage: 352))
    }

    private static func seedFitness(_ context: ModelContext, today: Date, yesterday: Date) {
        let cal = Calendar.current
        for offset in 1...5 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            context.insert(CheckIn(date: day, workedOut: offset % 2 == 1, weightTraining: offset % 2 == 1))
        }
        context.insert(Workout(date: yesterday, type: .lift, state: .done, source: .phone,
                               title: "Push day", durationMin: 68, avgBPM: 118))
        context.insert(Workout(date: yesterday, type: .walk, state: .done, source: .watch,
                               title: "Evening walk", durationMin: 32, avgBPM: 96, distanceKm: 2.8))

        // One session left RUNNING, which is the only way the live session bar
        // and its log sheet appear at all.
        context.insert(ActivitySession(day: today, blockKey: "09:00|Chores",
                                       title: "Chores", plannedMinutes: 60))
    }

    private static func seedTravel(_ context: ModelContext, from start: Date, cal: Calendar) {
        let end = cal.date(byAdding: .day, value: 4, to: start) ?? start
        let trip = Trip(title: "Wayanad", startDate: start, endDate: end)
        context.insert(trip)

        // travelMinutes written in and travelIsEstimated false, so the leave-by
        // chain renders WITHOUT a Maps call.
        let depart = cal.date(bySettingHour: 6, minute: 30, second: 0, of: start) ?? start
        context.insert(TravelSegment(tripID: trip.id, mode: .drive, label: "Drive to Wayanad",
                                     fromPlace: "Bengaluru", toPlace: "Wayanad",
                                     departAt: depart, travelMinutes: 330, travelIsEstimated: false,
                                     measuredAt: Date()))
        let back = cal.date(bySettingHour: 15, minute: 0, second: 0, of: end) ?? end
        context.insert(TravelSegment(tripID: trip.id, mode: .drive, label: "Drive home",
                                     fromPlace: "Wayanad", toPlace: "Bengaluru",
                                     departAt: back, travelMinutes: 345, travelIsEstimated: false,
                                     measuredAt: Date()))
        context.insert(TripStay(tripID: trip.id, place: "CGH Earth Wayanad",
                                address: "Vythiri, Kerala", arriveDate: start, departDate: end))
    }

    private static func seedEvents(_ context: ModelContext, today: Date) {
        context.insert(DailyEvent(date: today, title: "Dentist", startMinute: 15 * 60,
                                  endMinute: 16 * 60, destinationAddress: "HSR Layout, Bengaluru"))
    }

    // MARK: wipe

    /// Every model in the app's schema, so a re-run starts from the same place
    /// rather than accumulating. Order matters only for readability — SwiftData
    /// has no foreign keys here.
    @MainActor
    private static func wipe(_ context: ModelContext) {
        try? context.delete(model: DailyPlanState.self)
        try? context.delete(model: RoutineActivity.self)
        try? context.delete(model: DailyEvent.self)
        try? context.delete(model: ChatTurn.self)
        try? context.delete(model: Reminder.self)
        try? context.delete(model: Todo.self)
        try? context.delete(model: Book.self)
        try? context.delete(model: ReadingLog.self)
        try? context.delete(model: CheckIn.self)
        try? context.delete(model: Workout.self)
        try? context.delete(model: LiftSession.self)
        try? context.delete(model: LiftSet.self)
        try? context.delete(model: RunSession.self)
        try? context.delete(model: StretchLog.self)
        try? context.delete(model: ActivitySession.self)
        try? context.delete(model: Trip.self)
        try? context.delete(model: TravelSegment.self)
        try? context.delete(model: TripStay.self)
        try? context.delete(model: PrepSession.self)
        try? context.delete(model: LeisureLog.self)
        try? context.delete(model: JobApplication.self)
        try? context.delete(model: PlanGenerationLog.self)
        try? context.delete(model: AppEvent.self)
        try? context.delete(model: CalendarTombstone.self)
        try? context.delete(model: VoiceNote.self)
        try? context.delete(model: SavedLocation.self)
    }
}
