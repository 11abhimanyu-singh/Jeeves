//
//  DayPreferences.swift
//  Jeeves
//
//  The handful of numbers that shape a day and used to be constants in two
//  files each.
//
//  `dayStartMinute` lived as a `static let` in BOTH Baseline and DayPlanner,
//  with PlanGenerationService deriving its afternoon midpoint from the first —
//  so moving the start meant editing three places and hoping. `bodyWeightKg`
//  had no home at all: the lift logger defaulted every bodyweight-loaded set to
//  75 kg regardless of who was lifting.
//
//  UserDefaults rather than SwiftData on purpose: these are device
//  preferences read from non-view code (the planner, the prompt builder) where
//  a ModelContext isn't in scope, and they carry no history worth syncing.
//

import Foundation

enum DayPreferences {
    static let dayStartKey = "dayStartMinute"
    static let bodyWeightKey = "bodyWeightKg"

    static let defaultDayStartMinute = 8 * 60      // 8:00 AM
    static let defaultBodyWeightKg = 120.0

    /// When sleep ends. The day cannot begin producing before this — the hour
    /// between waking and the productive start is the morning routine.
    static let wakeMinute = 7 * 60                 // 7:00 AM, sleep 23:00 + 8h

    /// The morning-routine window: wake until work begins. Empty when the
    /// productive day starts at or before waking, in which case there is no
    /// routine block to place and the first block IS the first activity.
    static var morningRoutineWindow: (start: Int, end: Int)? {
        let start = dayStartMinute
        return start > wakeMinute ? (wakeMinute, start) : nil
    }

    /// When the productive day begins, in minutes past midnight.
    static var dayStartMinute: Int {
        let stored = UserDefaults.standard.integer(forKey: dayStartKey)
        // `integer(forKey:)` returns 0 for "never set", which is also a legal
        // midnight — but nobody starts their day at 00:00, and treating the
        // unset case as 8am is the behaviour every caller had before.
        guard stored > 0, stored < 24 * 60 else { return defaultDayStartMinute }
        return stored
    }

    /// Pre-fills the bodyweight on a bodyweight-loaded lift set. Per-set edits
    /// still win; this is only the starting number.
    static var bodyWeightKg: Double {
        let stored = UserDefaults.standard.double(forKey: bodyWeightKey)
        guard stored > 0 else { return defaultBodyWeightKg }
        return stored
    }

    /// "08:00"
    static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", (minute / 60) % 24, minute % 60)
    }
}
