//
//  Haptics.swift
//  Jeeves
//
//  The app had none. Completing a set, finishing a plan, checking off a to-do,
//  deleting a trip — all silent to the touch, which on iOS reads as unfinished.
//
//  The rule here is that a haptic must MEAN something, matching the intensity
//  to the consequence. Buzzing on every tap is noise, and noise trains people
//  to stop noticing the one buzz that mattered:
//
//    selection — you moved between things (a tab, a chip). Barely there.
//    success   — a thing was recorded (a set, a run, a plan landed).
//    warning   — something needs a second look before it is lost.
//    impact    — a discrete physical event (a countdown transition).
//
//  Deliberately no haptic on delete: the undo banner is the feedback, and a
//  buzz would reward the mis-tap it exists to catch.
//

import UIKit

@MainActor
enum Haptics {
    /// Moving between peers — tabs, chips, segments.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Something was written down and is now real.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Reversible, but worth noticing.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// A discrete event in a timed flow — the transition cue a guided run or
    /// stretch fires before each switch, where the user may not be looking at
    /// the screen at all. That is the case haptics exist for.
    static func cue() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
