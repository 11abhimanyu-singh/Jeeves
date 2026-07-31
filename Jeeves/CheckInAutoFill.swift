//
//  CheckInAutoFill.swift
//  Jeeves
//
//  The check-in's auto-derive layer: Jeeves already knows what you did — a
//  logged lift ticks Weight, a walk/run fills Cardio (with minutes + incline),
//  a stretch session ticks Stretching — so the daily check-in stops asking for
//  what the workout log can answer. Manual ticks still ADD (a session at a
//  friend's gym you never logged); they can't remove an auto tick.
//
//  Decisions encoded here (agreed 2026-07-28):
//    • Streak: a logged workout alone keeps the day alive — no check-in needed.
//    • Rest day: an explicit rest survives a walk ("Rest day · Walk 30min"),
//      but real training (lift / run / stretch) overrides it.
//    • Auto + manual override: merged = auto OR manual.
//
//  Everything is pure and value-typed so it unit-tests without a store.
//

import Foundation

enum CheckInAutoFill {

    /// One workout's contribution, as plain values.
    nonisolated struct WorkoutFact: Sendable, Equatable {
        var type: WorkoutType
        var finished: Bool          // live sessions don't count yet
        var durationMin: Int
        var incline: Double

        init(type: WorkoutType, finished: Bool = true, durationMin: Int = 0, incline: Double = 0) {
            self.type = type
            self.finished = finished
            self.durationMin = durationMin
            self.incline = incline
        }
    }

    /// The auto-derived layer for one day.
    nonisolated struct Derived: Sendable, Equatable {
        var weightTraining = false
        var stretching = false
        var cardio = false
        var cardioType: String?         // CheckIn's vocabulary: "Running" / "Inclined Walk"
        var cardioDuration: Double?     // minutes
        var cardioIncline: Double?      // percent
        // Walk detail kept separately so a rest day can still say "· Walk 30min".
        var walkMinutes = 0
        var walkIncline: Double = 0

        var cardioIsRun: Bool { cardioType == "Running" }
        /// Training that overrides an explicit rest mark (walks don't).
        var hasTraining: Bool { weightTraining || stretching || cardioIsRun }
        var hasAnything: Bool { weightTraining || stretching || cardio }
    }

    /// The manual layer, lifted out of a CheckIn record.
    nonisolated struct ManualFacts: Sendable, Equatable {
        var workedOut: Bool?            // nil = never answered
        var weightTraining = false
        var stretching = false
        var mobility = false
        var cardio = false
        var cardioType: String?
        var cardioDuration: Double?
        var cardioIncline: Double?

        init(workedOut: Bool? = nil, weightTraining: Bool = false, stretching: Bool = false,
             mobility: Bool = false, cardio: Bool = false, cardioType: String? = nil,
             cardioDuration: Double? = nil, cardioIncline: Double? = nil) {
            self.workedOut = workedOut
            self.weightTraining = weightTraining
            self.stretching = stretching
            self.mobility = mobility
            self.cardio = cardio
            self.cardioType = cardioType
            self.cardioDuration = cardioDuration
            self.cardioIncline = cardioIncline
        }
    }

    /// A day as the streak, history and summaries see it: merged auto ∪ manual.
    nonisolated struct DayStatus: Sendable, Equatable {
        var isRest: Bool
        var qualifies: Bool             // counts toward the streak / monthly goal
        var summary: String
    }

    // MARK: Derivation

    /// Fold a day's workouts + stretch sessions into the auto layer.
    /// Cardio detail prefers the run (training cardio); the longest walk fills
    /// in otherwise. Unfinished (live) workouts contribute nothing yet.
    nonisolated static func derive(_ workouts: [WorkoutFact], stretchCount: Int = 0) -> Derived {
        var d = Derived()
        let done = workouts.filter(\.finished)
        d.weightTraining = done.contains { $0.type == .lift }
        d.stretching = stretchCount > 0

        if let walk = done.filter({ $0.type == .walk }).max(by: { $0.durationMin < $1.durationMin }) {
            d.walkMinutes = walk.durationMin
            d.walkIncline = walk.incline
        }
        if let run = done.filter({ $0.type == .run }).max(by: { $0.durationMin < $1.durationMin }) {
            d.cardio = true
            d.cardioType = "Running"
            d.cardioDuration = run.durationMin > 0 ? Double(run.durationMin) : nil
        } else if d.walkMinutes > 0 || done.contains(where: { $0.type == .walk }) {
            d.cardio = true
            d.cardioType = "Inclined Walk"
            d.cardioDuration = d.walkMinutes > 0 ? Double(d.walkMinutes) : nil
            d.cardioIncline = d.walkIncline > 0 ? d.walkIncline : nil
        }
        return d
    }

    nonisolated static func manualFacts(workedOut: Bool?, weightTraining: Bool, stretching: Bool,
                                        mobility: Bool, cardio: Bool, cardioType: String?,
                                        cardioDuration: Double?, cardioIncline: Double?) -> ManualFacts {
        ManualFacts(workedOut: workedOut, weightTraining: weightTraining, stretching: stretching,
                    mobility: mobility, cardio: cardio, cardioType: cardioType,
                    cardioDuration: cardioDuration, cardioIncline: cardioIncline)
    }

    // MARK: Merge

    /// The merged day: auto OR manual, with rest-day and streak semantics.
    /// Returns nil when the day has nothing at all (no check-in, no workouts) —
    /// history has no row and the streak stops.
    nonisolated static func mergedDay(auto: Derived, manual: ManualFacts?) -> DayStatus? {
        let m = manual ?? ManualFacts()
        let hasManual = manual != nil && (m.workedOut != nil)
        guard hasManual || auto.hasAnything else { return nil }

        // Explicit rest stands unless real training was logged (walks allowed).
        if m.workedOut == false && !auto.hasTraining {
            var s = "Rest day"
            if auto.walkMinutes > 0 {
                s += " \u{00B7} Walk \(auto.walkMinutes)min"
                if auto.walkIncline > 0 { s += ", \(trim(auto.walkIncline))%" }
            } else if auto.cardio {
                s += " \u{00B7} Walk"
            }
            return DayStatus(isRest: true, qualifies: false, summary: s)
        }

        var parts: [String] = []
        if auto.weightTraining || m.weightTraining { parts.append("Weight") }
        if auto.stretching || m.stretching { parts.append("Stretch") }
        if m.mobility { parts.append("Mobility") }
        // Cardio can come from both layers and they may describe DIFFERENT
        // sessions (a manually recorded run + a logged walk). Report each once,
        // rather than letting the auto layer mask the manual one wholesale.
        var cardioBits: [String] = []
        if auto.cardio {
            cardioBits.append(cardioPhrase(type: auto.cardioType, minutes: auto.cardioDuration,
                                           incline: auto.cardioIncline))
        }
        if m.cardio {
            // Only add the manual entry when it isn't the same activity the
            // workout log already described.
            let sameActivity = auto.cardio && (m.cardioType == nil || m.cardioType == auto.cardioType)
            if !sameActivity {
                cardioBits.append(cardioPhrase(type: m.cardioType, minutes: m.cardioDuration,
                                               incline: m.cardioIncline))
            }
        }
        if !cardioBits.isEmpty {
            parts.append("Cardio (" + cardioBits.joined(separator: " + ") + ")")
        }

        let qualifies = m.workedOut == true || auto.hasAnything || !parts.isEmpty
        return DayStatus(isRest: false, qualifies: qualifies,
                         summary: parts.isEmpty ? "Logged" : parts.joined(separator: " \u{00B7} "))
    }

    /// "Walk, 32min, 4%" — one cardio session described from whichever layer
    /// holds it.
    nonisolated private static func cardioPhrase(type: String?, minutes: Double?,
                                                 incline: Double?) -> String {
        var s = type == "Running" ? "Run" : (type == nil ? "logged" : "Walk")
        if let minutes { s += ", \(Int(minutes))min" }
        if let incline, incline > 0 { s += ", \(trim(incline))%" }
        return s
    }

    nonisolated private static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    /// Consecutive qualifying days ending at `today` — or ending yesterday when
    /// today hasn't been logged yet, so an unlogged morning doesn't read as a
    /// broken streak. `status` answers for one day (nil = nothing recorded).
    ///
    /// Pure, so the rule is tested rather than trusted: the view used to walk
    /// back from whatever day the check-in form was editing, which defaults to
    /// yesterday — fine while it was buried in Fitness, wrong once Progress
    /// became the launch screen.
    nonisolated static func streak(endingAt today: Date,
                                   calendar: Calendar = .current,
                                   status: (Date) -> DayStatus?) -> Int {
        var cursor = calendar.startOfDay(for: today)
        if status(cursor)?.qualifies != true {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var count = 0
        while status(cursor)?.qualifies == true {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
}
