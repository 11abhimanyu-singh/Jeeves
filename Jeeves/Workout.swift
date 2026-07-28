//
//  Workout.swift
//  Jeeves
//
//  The unified workout container. One Workout = one session (lift / run /
//  walk), usually born on the Apple Watch (which contributes duration + heart
//  rate) and enriched on the phone (lift exercises & sets, walk incline). A
//  lift Workout owns its exercises via LiftSession.workoutID; a run keeps its
//  detail in RunSession; a walk stores minutes + incline directly here.
//
//  All stored properties carry defaults so CloudKit mirroring stays happy
//  (same convention as every other @Model in the app).
//

import Foundation
import SwiftData

enum WorkoutType: String, CaseIterable {
    case lift, run, walk

    /// Maps the watch's activity codes ("strength", "walkIndoor", …) to a type.
    nonisolated static func from(activity: String) -> WorkoutType {
        switch activity {
        case "strength":                  return .lift
        case "walkIndoor", "walkOutdoor": return .walk
        default:                          return .run
        }
    }

    /// Default card title for a watch-born workout of this type.
    nonisolated static func title(forActivity activity: String) -> String {
        switch activity {
        case "strength":    return "Lifting"
        case "walkIndoor":  return "Indoor Walk"
        case "walkOutdoor": return "Outdoor Walk"
        default:            return "Run"
        }
    }
}

enum WorkoutState: String {
    case live          // in progress (watch is running it right now)
    case needsDetail   // finished, waiting for the user to fill in sets/incline
    case done          // fully logged
}

enum WorkoutSource: String {
    case watch    // started on the Apple Watch (has real duration + HR)
    case phone    // started by the phone's own tool (the run screen)
    case manual   // logged after the fact, no device data
}

@Model
final class Workout {
    var id: UUID = UUID()
    var date: Date = Date.distantPast      // session start
    var typeRaw: String = WorkoutType.lift.rawValue
    var stateRaw: String = WorkoutState.needsDetail.rawValue
    var sourceRaw: String = WorkoutSource.manual.rawValue
    var title: String = ""
    var durationMin: Int = 0               // 0 = unknown (manual entries)
    var avgBPM: Int = 0                    // 0 = none captured
    var distanceKm: Double = 0             // runs (and future outdoor walks)
    var inclinePercent: Double = 0         // walks

    var type: WorkoutType {
        get { WorkoutType(rawValue: typeRaw) ?? .lift }
        set { typeRaw = newValue.rawValue }
    }
    var state: WorkoutState {
        get { WorkoutState(rawValue: stateRaw) ?? .done }
        set { stateRaw = newValue.rawValue }
    }
    var source: WorkoutSource {
        get { WorkoutSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), date: Date, type: WorkoutType, state: WorkoutState,
         source: WorkoutSource, title: String, durationMin: Int = 0, avgBPM: Int = 0,
         distanceKm: Double = 0, inclinePercent: Double = 0) {
        self.id = id
        self.date = date
        self.typeRaw = type.rawValue
        self.stateRaw = state.rawValue
        self.sourceRaw = source.rawValue
        self.title = title
        self.durationMin = durationMin
        self.avgBPM = avgBPM
        self.distanceKm = distanceKm
        self.inclinePercent = inclinePercent
    }
}

// MARK: - Migration of pre-Workout data

extension Workout {
    /// Pure day-grouping used by the migration (and unit-testable without a
    /// store): buckets items by calendar day of their date.
    nonisolated static func groupedByDay<T>(_ items: [T], date: (T) -> Date,
                                            calendar: Calendar = .current) -> [Date: [T]] {
        Dictionary(grouping: items) { calendar.startOfDay(for: date($0)) }
    }

    /// One-time upgrade: wrap every pre-existing LiftSession and RunSession in
    /// a Workout so old logs appear in Today/History. Lift sessions from the
    /// same calendar day merge into one workout (the new mental model: a day's
    /// exercises = one session); each run becomes its own workout. Safe to call
    /// every launch — a UserDefaults flag makes it run once.
    static func migrateIfNeeded(context: ModelContext) {
        let flag = "workoutModelMigrated.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }

        let lifts = ((try? context.fetch(FetchDescriptor<LiftSession>())) ?? [])
            .filter { $0.workoutID == nil }
        for (day, sessions) in groupedByDay(lifts, date: { $0.date }) {
            let start = sessions.map(\.date).min() ?? day
            let workout = Workout(date: start, type: .lift, state: .done, source: .manual,
                                  title: "Lift", avgBPM: sessions.map(\.avgBPM).max() ?? 0)
            context.insert(workout)
            for s in sessions { s.workoutID = workout.id }
        }

        let runs = ((try? context.fetch(FetchDescriptor<RunSession>())) ?? [])
            .filter { $0.workoutID == nil }
        for r in runs {
            let workout = Workout(date: r.date, type: .run, state: .done, source: .phone,
                                  title: "Run \u{00B7} Week \(r.weekIndex + 1)",
                                  durationMin: r.durationSec / 60,
                                  avgBPM: r.avgHeartRate ?? 0,
                                  distanceKm: r.distanceKm)
            context.insert(workout)
            r.workoutID = workout.id
        }

        if context.saveOrLog("Workout.migrate") {
            UserDefaults.standard.set(true, forKey: flag)
        }
    }
}
