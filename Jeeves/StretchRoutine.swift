//
//  StretchRoutine.swift
//  Jeeves
//
//  The stretching / mobility flow's data. Routines themselves are fixed
//  editorial content (value types, not SwiftData) — a named ordered list of
//  moves, each with a hold and an optional per-side flag. Only the *completion*
//  is persisted, as a StretchLog, so the Fitness module can count sessions and
//  the state export can mirror them. All StretchLog stored properties carry
//  defaults so the model is CloudKit-ready.
//

import Foundation
import SwiftData

// MARK: - Move

/// One hold in a routine. `perSide` means the flow runs it twice — left, then
/// right — so a 30s per-side move is a full minute of work.
struct StretchMove: Identifiable, Hashable {
    let id = UUID()
    var name: String        // e.g. "Standing quad"
    var target: String      // the area it opens, e.g. "Quads & hip flexors"
    var holdSeconds: Int    // hold length for ONE side (or the whole move if not per-side)
    var perSide: Bool       // true = repeat left then right

    init(_ name: String, target: String, holdSeconds: Int, perSide: Bool = false) {
        self.name = name
        self.target = target
        self.holdSeconds = holdSeconds
        self.perSide = perSide
    }
}

// MARK: - Routine

/// A named, ordered sequence of moves. `totalSeconds` counts per-side moves
/// twice, so it matches the real guided-flow length the picker advertises.
struct StretchRoutine: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var subtitle: String        // one-line "when to use it" note for the picker
    var moves: [StretchMove]

    /// Wall-clock length of the guided flow, per-side moves counted twice.
    var totalSeconds: Int {
        moves.reduce(0) { $0 + $1.holdSeconds * ($1.perSide ? 2 : 1) }
    }

    /// Rounded whole minutes, for the picker label ("~6 min").
    var approxMinutes: Int {
        Int((Double(totalSeconds) / 60).rounded())
    }

    /// How many timed segments the flow will run (per-side moves = 2).
    var segmentCount: Int {
        moves.reduce(0) { $0 + ($1.perSide ? 2 : 1) }
    }
}

// MARK: - Built-in routines

extension StretchRoutine {
    /// Post-workout static holds to bring the heart rate down and unwind the
    /// big movers. ~6 min.
    static let coolDown = StretchRoutine(
        name: "Cool-down",
        subtitle: "Wind down the big movers after training",
        moves: [
            StretchMove("Neck & shoulder rolls", target: "Neck & upper traps", holdSeconds: 30),
            StretchMove("Standing quad",        target: "Quads & hip flexors", holdSeconds: 30, perSide: true),
            StretchMove("Standing hamstring reach", target: "Hamstrings",      holdSeconds: 30, perSide: true),
            StretchMove("Figure-4 glute",       target: "Glutes & outer hip",  holdSeconds: 30, perSide: true),
            StretchMove("Calf wall push",       target: "Calves & Achilles",   holdSeconds: 30, perSide: true),
            StretchMove("Seated spinal twist",  target: "Spine & obliques",    holdSeconds: 30, perSide: true),
            StretchMove("Child's pose",         target: "Lower back & lats",   holdSeconds: 45),
        ]
    )

    /// Wake-the-body flow — spine, hips, and a little core activation. ~5 min.
    static let morningMobility = StretchRoutine(
        name: "Morning mobility",
        subtitle: "Loosen the spine & hips to start the day",
        moves: [
            StretchMove("Neck & shoulder rolls", target: "Neck & shoulders",   holdSeconds: 25),
            StretchMove("Cat-Camel",             target: "Spine mobility",      holdSeconds: 40),
            StretchMove("Hip-flexor lunge",      target: "Hip flexors",         holdSeconds: 30, perSide: true),
            StretchMove("Standing hamstring reach", target: "Hamstrings",       holdSeconds: 25, perSide: true),
            StretchMove("Dead Bug",              target: "Core & lower back",   holdSeconds: 30),
            StretchMove("Figure-4 glute",        target: "Glutes & outer hip",  holdSeconds: 25, perSide: true),
            StretchMove("Hollow Hold",           target: "Deep core",           holdSeconds: 30),
        ]
    )

    /// Short reset for a long sitting stretch — neck, spine, hips, calves. ~3 min.
    static let deskReset = StretchRoutine(
        name: "Desk reset",
        subtitle: "Quick unwind after a long sitting stretch",
        moves: [
            StretchMove("Neck & shoulder rolls", target: "Neck & upper traps", holdSeconds: 30),
            StretchMove("Seated spinal twist",   target: "Spine & obliques",   holdSeconds: 25, perSide: true),
            StretchMove("Standing quad",         target: "Quads & hip flexors", holdSeconds: 25, perSide: true),
            StretchMove("Calf wall push",        target: "Calves & Achilles",  holdSeconds: 25, perSide: true),
            StretchMove("Child's pose",          target: "Lower back & lats",  holdSeconds: 40),
        ]
    )

    /// Picker order.
    static let all: [StretchRoutine] = [coolDown, morningMobility, deskReset]
}

// MARK: - Log

/// One completed (or ended-early) stretching session. `durationSec` is the time
/// actually spent stretching, not the routine's nominal length.
@Model
final class StretchLog {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var routineName: String = ""
    var durationSec: Int = 0

    init(id: UUID = UUID(), date: Date, routineName: String, durationSec: Int) {
        self.id = id
        self.date = date
        self.routineName = routineName
        self.durationSec = durationSec
    }
}
