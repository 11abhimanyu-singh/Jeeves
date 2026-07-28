//
//  RunProgram.swift
//  Jeeves
//
//  The couch-to-5K plan's data. The 16-week programme itself is fixed editorial
//  content (value types, not SwiftData): a table of weeks, each an ordered list
//  of RunSegments the live-run screen walks through. Only the *completion* is
//  persisted, as a RunSession, so the Fitness module can count runs, track which
//  week you're on, and the state export can mirror them. All RunSession stored
//  properties carry defaults so the model is CloudKit-ready.
//
//  Design of the progression: a true-beginner, 3-sessions/week plan stretched
//  over 16 weeks (gentler than the classic 9-week C25K). The safe, meaningful
//  driver is the *longest continuous run block*, which grows monotonically —
//  1 → 30 min — while walk breaks shrink and eventually disappear. Total running
//  volume plateaus on consolidation weeks (e.g. W8, W11) rather than spiking:
//  every step up is gentle, never a big jump. By week 16 it's 30 min non-stop.
//  (The ~5K distance follows as pace improves past the 7 km/h planning default —
//  the primary goal is the unbroken 30-minute run.)
//

import Foundation
import SwiftData

// MARK: - Segment

/// The kind of a single timed block within a session.
enum RunSegmentKind: String, CaseIterable, Hashable {
    case warmup, run, walk, cooldown

    var display: String {
        switch self {
        case .warmup:   return "Warm-up"
        case .run:      return "Run"
        case .walk:     return "Walk"
        case .cooldown: return "Cool-down"
        }
    }

    /// SF Symbol for the block (all ship on iOS 16+).
    var icon: String {
        switch self {
        case .warmup:   return "figure.walk"
        case .run:      return "figure.run"
        case .walk:     return "figure.walk"
        case .cooldown: return "figure.cooldown"
        }
    }
}

/// One ordered, timed block of a session. Stored as `kindRaw: String` (mirroring
/// the @Model enum-as-raw-String convention) with a computed accessor; `seconds`
/// is the block length and `targetKmh` the treadmill/target pace to hold.
struct RunSegment: Identifiable, Hashable {
    let id = UUID()
    var kindRaw: String     // RunSegmentKind raw value
    var seconds: Int
    var targetKmh: Double

    var kind: RunSegmentKind { RunSegmentKind(rawValue: kindRaw) ?? .run }

    init(kindRaw: String, seconds: Int, targetKmh: Double) {
        self.kindRaw = kindRaw
        self.seconds = seconds
        self.targetKmh = targetKmh
    }

    // Convenience builders. Default paces: walk 5.0 km/h, run 7.0 km/h; the
    // warm-up and cool-down are run at the walk pace.
    static func warmup(_ seconds: Int = 300, kmh: Double = 5.0) -> RunSegment {
        RunSegment(kindRaw: RunSegmentKind.warmup.rawValue, seconds: seconds, targetKmh: kmh)
    }
    static func run(_ seconds: Int, kmh: Double = 7.0) -> RunSegment {
        RunSegment(kindRaw: RunSegmentKind.run.rawValue, seconds: seconds, targetKmh: kmh)
    }
    static func walk(_ seconds: Int, kmh: Double = 5.0) -> RunSegment {
        RunSegment(kindRaw: RunSegmentKind.walk.rawValue, seconds: seconds, targetKmh: kmh)
    }
    static func cooldown(_ seconds: Int = 300, kmh: Double = 5.0) -> RunSegment {
        RunSegment(kindRaw: RunSegmentKind.cooldown.rawValue, seconds: seconds, targetKmh: kmh)
    }
}

// MARK: - Week / Day

/// One week of the plan: a single session template plus a one-line focus. All
/// three sessions in a week run the same workout (as the classic C25K does), so
/// the three days share this week's `segments`.
struct RunWeek: Identifiable, Hashable {
    let id = UUID()
    var index: Int          // 0-based week number
    var focus: String       // e.g. "Run 2 min · walk 90 sec × 6"
    var segments: [RunSegment]

    /// Human week number (1-based) for display.
    var number: Int { index + 1 }

    /// Wall-clock length of one session.
    var totalSeconds: Int { segments.reduce(0) { $0 + $1.seconds } }

    /// Seconds of actual running (excludes warm-up walk / cool-down / walk breaks).
    var runSeconds: Int {
        segments.filter { $0.kind == .run }.reduce(0) { $0 + $1.seconds }
    }

    /// Longest unbroken run block — the metric the plan progresses on.
    var longestRunSeconds: Int {
        segments.filter { $0.kind == .run }.map(\.seconds).max() ?? 0
    }

    /// Planned distance of one full session at the target paces.
    var distanceKm: Double { RunSession.distanceKm(for: segments) }

    /// The week expanded into its three (identical) days.
    var days: [RunDay] {
        (0..<RunProgram.sessionsPerWeek).map { RunDay(weekIndex: index, dayIndex: $0, segments: segments) }
    }
}

/// One dated session slot within a week. Identical segments across the week's
/// three days; carried separately so callers can address "week X, day Y".
struct RunDay: Identifiable, Hashable {
    let id = UUID()
    var weekIndex: Int
    var dayIndex: Int
    var segments: [RunSegment]
}

// MARK: - Programme

enum RunProgram {
    static let totalWeeks = 16
    static let sessionsPerWeek = 3

    /// Build an interval session: a walk warm-up, `reps` of run→walk (the last
    /// run flows straight into the cool-down, no trailing walk), then a cool-down.
    private static func intervals(warmup: Int = 300, run runSec: Int, walk walkSec: Int,
                                  reps: Int, cooldown: Int = 300) -> [RunSegment] {
        var segs: [RunSegment] = [.warmup(warmup)]
        for i in 0..<reps {
            segs.append(.run(runSec))
            if i < reps - 1 { segs.append(.walk(walkSec)) }
        }
        segs.append(.cooldown(cooldown))
        return segs
    }

    /// The full 16-week table. Longest run block climbs
    /// 1 → 1½ → 2 → 2½ → 3 → 4 → 5 → 6 → 7 → 8 → 10 → 12 → 15 → 20 → 25 → 30 min,
    /// walk breaks ease from 90s toward none, ending in an unbroken 30-minute run.
    static let weeks: [RunWeek] = [
        // — Phase 1: short runs, generous walks (get the body used to running) —
        RunWeek(index: 0,  focus: "Run 1 min · walk 90 sec × 8",
                segments: intervals(run: 60,  walk: 90, reps: 8)),
        RunWeek(index: 1,  focus: "Run 90 sec · walk 90 sec × 7",
                segments: intervals(run: 90,  walk: 90, reps: 7)),
        RunWeek(index: 2,  focus: "Run 2 min · walk 90 sec × 6",
                segments: intervals(run: 120, walk: 90, reps: 6)),
        RunWeek(index: 3,  focus: "Run 2½ min · walk 90 sec × 5",
                segments: intervals(run: 150, walk: 90, reps: 5)),
        RunWeek(index: 4,  focus: "Run 3 min · walk 90 sec × 5",
                segments: intervals(run: 180, walk: 90, reps: 5)),

        // — Phase 2: runs lengthen, fewer & shorter walks —
        RunWeek(index: 5,  focus: "Run 4 min · walk 90 sec × 4",
                segments: intervals(run: 240, walk: 90, reps: 4)),
        RunWeek(index: 6,  focus: "Run 5 min · walk 90 sec × 4",
                segments: intervals(run: 300, walk: 90, reps: 4)),
        RunWeek(index: 7,  focus: "Run 6 min · walk 90 sec × 3",
                segments: intervals(run: 360, walk: 90, reps: 3)),
        RunWeek(index: 8,  focus: "Run 7 min · walk 90 sec × 3",
                segments: intervals(run: 420, walk: 90, reps: 3)),
        RunWeek(index: 9,  focus: "Run 8 min · walk 2 min × 3",
                segments: intervals(run: 480, walk: 120, reps: 3)),

        // — Phase 3: consolidate into long continuous blocks —
        RunWeek(index: 10, focus: "Run 10 min · walk 2 min × 2",
                segments: intervals(run: 600, walk: 120, reps: 2)),
        RunWeek(index: 11, focus: "Run 12 min · walk 2 min × 2",
                segments: intervals(run: 720, walk: 120, reps: 2)),
        RunWeek(index: 12, focus: "Run 15 min · walk 2 min × 2",
                segments: intervals(run: 900, walk: 120, reps: 2)),
        RunWeek(index: 13, focus: "Run 20 min · walk 2 min · run 10 min",
                segments: [.warmup(), .run(1200), .walk(120), .run(600), .cooldown()]),
        RunWeek(index: 14, focus: "Run 25 min · walk 2 min · run 5 min",
                segments: [.warmup(), .run(1500), .walk(120), .run(300), .cooldown()]),

        // — Goal: 30 minutes, non-stop —
        RunWeek(index: 15, focus: "Run 30 min · non-stop",
                segments: [.warmup(), .run(1800), .cooldown()]),
    ]

    /// The week for a 0-based index, clamped to the table.
    static func week(_ index: Int) -> RunWeek {
        weeks[min(max(index, 0), weeks.count - 1)]
    }
}

// MARK: - Logged session

/// One completed (or ended-early) run. `durationSec` and `distanceKm` reflect
/// what was actually covered, not the week's nominal plan. `rpe` is the 1–10
/// rate-of-perceived-exertion the runner logs afterward.
@Model
final class RunSession {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var weekIndex: Int = 0
    var dayIndex: Int = 0
    var durationSec: Int = 0
    var distanceKm: Double = 0
    var avgHeartRate: Int? = nil    // HealthKit integration point — stubbed nil until wired
    var rpe: Int = 0
    var workoutID: UUID? = nil      // owning Workout (the Today/History container)

    init(id: UUID = UUID(), date: Date, weekIndex: Int, dayIndex: Int,
         durationSec: Int, distanceKm: Double, avgHeartRate: Int? = nil, rpe: Int,
         workoutID: UUID? = nil) {
        self.id = id
        self.date = date
        self.weekIndex = weekIndex
        self.dayIndex = dayIndex
        self.durationSec = durationSec
        self.distanceKm = distanceKm
        self.avgHeartRate = avgHeartRate
        self.rpe = rpe
        self.workoutID = workoutID
    }

    /// Pure helper: distance covered by a list of segments at their target paces,
    /// summing (km/h × seconds ÷ 3600). Used both to preview a planned session and
    /// to compute the logged distance (over the segments actually completed).
    static func distanceKm(for segments: [RunSegment]) -> Double {
        segments.reduce(0.0) { $0 + $1.targetKmh * Double($1.seconds) / 3600.0 }
    }
}
