//
//  LiftLog.swift
//  Jeeves
//
//  The weightlifting logger's data. A LiftSession is one exercise's worth of
//  work on a given day; each LiftSet under it records reps × load, linked back
//  by a UUID foreign key (no @Relationship, per the CloudKit rules). The tonnage
//  math lives as pure, SwiftData-free functions so it's trivially testable and
//  callable off the main store. All @Model stored properties carry defaults so
//  the models are CloudKit-ready.
//

import Foundation
import SwiftData

// MARK: - Input type

/// How a set's load is measured. Drives which fields the logger shows and how
/// tonnage is computed.
enum LiftInputType: String, CaseIterable {
    case weighted       // external load only (barbell, dumbbell, machine)
    case bodyweight     // moves your own mass, optionally plus added load
    case isometric      // a timed hold — no reps, tracked by seconds instead

    var label: String {
        switch self {
        case .weighted:   return "Weighted"
        case .bodyweight: return "Bodyweight"
        case .isometric:  return "Isometric"
        }
    }
}

// MARK: - Models

/// One exercise logged on one day. Its sets are linked by `sessionID`, not a
/// SwiftData relationship, so CloudKit stays happy.
@Model
final class LiftSession {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var exerciseName: String = ""
    var avgBPM: Int = 0   // average heart rate over the session; 0 = none captured
    var workoutID: UUID? = nil   // owning Workout (one workout = the day's exercises)

    init(id: UUID = UUID(), date: Date, exerciseName: String, avgBPM: Int = 0,
         workoutID: UUID? = nil) {
        self.id = id
        self.date = date
        self.exerciseName = exerciseName
        self.avgBPM = avgBPM
        self.workoutID = workoutID
    }
}

/// A single working set. `inputType` is stored as a raw String (CloudKit can't
/// hold an enum) with a computed accessor. Isometric sets carry `holdSeconds`
/// and contribute zero rep-tonnage.
@Model
final class LiftSet {
    var id: UUID = UUID()
    var sessionID: UUID = UUID()          // foreign key back to LiftSession.id
    var order: Int = 0                    // display / fill order within the session
    var reps: Int = 0
    var weightKg: Double = 0
    var inputTypeRaw: String = LiftInputType.weighted.rawValue
    var holdSeconds: Int = 0              // isometric only
    var addedKg: Double = 0              // bodyweight only — belt/vest/dumbbell load
    var bodyweightKg: Double = 0          // bodyweight only — the lifter's mass

    var inputType: LiftInputType {
        get { LiftInputType(rawValue: inputTypeRaw) ?? .weighted }
        set { inputTypeRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), sessionID: UUID, order: Int, reps: Int = 0,
         weightKg: Double = 0, inputType: LiftInputType = .weighted,
         holdSeconds: Int = 0, addedKg: Double = 0, bodyweightKg: Double = 0) {
        self.id = id
        self.sessionID = sessionID
        self.order = order
        self.reps = reps
        self.weightKg = weightKg
        self.inputTypeRaw = inputType.rawValue
        self.holdSeconds = holdSeconds
        self.addedKg = addedKg
        self.bodyweightKg = bodyweightKg
    }
}

// MARK: - Tonnage math (pure, testable, no SwiftData required)

/// Volume-load ("tonnage") arithmetic. The raw-field entry point is `nonisolated`
/// so the math can be exercised from a plain unit test with no store, no main
/// actor, and no model instances.
enum LiftMath {
    /// Tonnage for one set from its raw fields.
    ///  - weighted:   reps × external weight
    ///  - bodyweight: reps × (bodyweight + added load)
    ///  - isometric:  0 (a hold moves no reps; track `holdSeconds` separately)
    nonisolated static func setTonnage(inputType: LiftInputType, reps: Int,
                                       weightKg: Double, bodyweightKg: Double,
                                       addedKg: Double) -> Double {
        switch inputType {
        case .weighted:   return Double(reps) * weightKg
        case .bodyweight: return Double(reps) * (bodyweightKg + addedKg)
        case .isometric:  return 0
        }
    }

    /// Convenience over a persisted set.
    static func setTonnage(_ set: LiftSet) -> Double {
        setTonnage(inputType: set.inputType, reps: set.reps, weightKg: set.weightKg,
                   bodyweightKg: set.bodyweightKg, addedKg: set.addedKg)
    }

    /// Sum a session's sets to its total tonnage.
    static func sessionTonnage(_ sets: [LiftSet]) -> Double {
        sets.reduce(0) { $0 + setTonnage($1) }
    }

    /// Total isometric hold time across a session's sets (weighted/bodyweight
    /// sets contribute nothing here).
    static func totalHoldSeconds(_ sets: [LiftSet]) -> Int {
        sets.reduce(0) { $0 + ($1.inputType == .isometric ? $1.holdSeconds : 0) }
    }
}

// MARK: - Exercise library

/// The muscle-group buckets the picker organizes exercises into.
enum LiftGroup: String, CaseIterable {
    case olympic        = "Olympic"
    case legs           = "Legs"
    case back           = "Back"
    case chestShoulders = "Chest & Shoulders"
    case arms           = "Arms"
    case core           = "Core"
}

/// One named exercise and the group it belongs to. Value type (fixed editorial
/// content), so it isn't persisted — a logged session only stores the name.
struct LiftExercise: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let group: LiftGroup

    init(_ name: String, _ group: LiftGroup) {
        self.name = name
        self.group = group
    }
}

extension LiftExercise {
    /// The built-in catalogue, grouped Olympic → Legs → Back → Chest & Shoulders
    /// → Arms → Core. Names are unique (they double as the `id`).
    static let library: [LiftExercise] = [
        // Olympic
        LiftExercise("Snatch",                     .olympic),
        LiftExercise("Power Snatch",               .olympic),
        LiftExercise("Hang Snatch",                .olympic),
        LiftExercise("Snatch Balance",             .olympic),
        LiftExercise("Overhead Squat",             .olympic),
        LiftExercise("Clean & Jerk",               .olympic),
        LiftExercise("Clean (Barbell)",            .olympic),
        LiftExercise("Power Clean",                .olympic),
        LiftExercise("Hang Clean",                 .olympic),
        LiftExercise("Clean Pull (Barbell)",       .olympic),
        LiftExercise("Snatch High Pull (Barbell)", .olympic),
        LiftExercise("Clean High Pull (Barbell)",  .olympic),
        LiftExercise("Push Jerk",                  .olympic),
        LiftExercise("Split Jerk",                 .olympic),

        // Legs
        LiftExercise("Front Squat",                .legs),
        LiftExercise("Back Squat",                 .legs),
        LiftExercise("Romanian Deadlift",          .legs),
        LiftExercise("Bulgarian Split Squat",      .legs),
        LiftExercise("Goblet Squat",               .legs),
        LiftExercise("Leg Press",                  .legs),
        LiftExercise("Walking Lunge",              .legs),
        LiftExercise("Hip Thrust",                 .legs),
        LiftExercise("Leg Curl",                   .legs),
        LiftExercise("Leg Extension",              .legs),
        LiftExercise("Standing Calf Raise",        .legs),

        // Back
        LiftExercise("Deadlift (Barbell)",         .back),
        LiftExercise("Pull-Up",                    .back),
        LiftExercise("Chin-Up",                    .back),
        LiftExercise("Lat Pulldown",               .back),
        LiftExercise("Wide-Grip Row",              .back),
        LiftExercise("Bent-Over Row (Barbell)",    .back),
        LiftExercise("Single-Arm Bent-Over Row",   .back),
        LiftExercise("Incline Dumbbell Row",       .back),
        LiftExercise("Seated Cable Row",           .back),
        LiftExercise("T-Bar Row",                  .back),
        LiftExercise("Cable Face Pull",            .back),

        // Chest & Shoulders
        LiftExercise("Bench Press",                .chestShoulders),
        LiftExercise("Incline Bench Press",        .chestShoulders),
        LiftExercise("Dumbbell Bench Press",       .chestShoulders),
        LiftExercise("Cable Fly",                  .chestShoulders),
        LiftExercise("Dip",                        .chestShoulders),
        LiftExercise("Military Press",             .chestShoulders),
        LiftExercise("Z-Press",                    .chestShoulders),
        LiftExercise("Standing Shoulder Press",    .chestShoulders),
        LiftExercise("Seated Shoulder Press",      .chestShoulders),
        LiftExercise("Push Press (Barbell)",       .chestShoulders),
        LiftExercise("Arnold Press",               .chestShoulders),
        LiftExercise("Lateral Raise",              .chestShoulders),
        LiftExercise("Rear Delt Fly",              .chestShoulders),

        // Arms
        LiftExercise("Standing Biceps Curl",       .arms),
        LiftExercise("Standing Hammer Curl",       .arms),
        LiftExercise("Seated Biceps Curl",         .arms),
        LiftExercise("Seated Incline Curl",        .arms),
        LiftExercise("Preacher Curl",              .arms),
        LiftExercise("Concentration Curl",         .arms),
        LiftExercise("Overhead Triceps Extension", .arms),
        LiftExercise("Rope Pushdown",              .arms),
        LiftExercise("Skull Crusher",              .arms),
        LiftExercise("Close-Grip Bench Press",     .arms),

        // Core
        LiftExercise("Plank",                      .core),
        LiftExercise("Hollow Hold",                .core),
        LiftExercise("Dead Bug",                   .core),
        LiftExercise("Cat-Camel",                  .core),
        LiftExercise("Hanging Leg Raise",          .core),
        LiftExercise("Ab Wheel Rollout",           .core),
        LiftExercise("Cable Crunch",               .core),
        LiftExercise("Russian Twist",              .core),
    ]
}
