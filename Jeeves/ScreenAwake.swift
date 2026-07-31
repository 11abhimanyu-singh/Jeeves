//
//  ScreenAwake.swift
//  Jeeves
//
//  Hands-off timed flows — the guided run and the guided stretch — are worth
//  nothing if the screen locks halfway through. Both are watched, not touched:
//  a countdown and a transition cue are the entire interface, and the default
//  auto-lock puts them behind a lock screen mid-session.
//
//  Refcounted rather than a bare boolean, because the run screen holds it
//  while the stretch screen can be pushed over it; the last one out turns it
//  off. A leaked hold would keep a user's screen on until they killed the app,
//  so `releaseAll` exists for lifecycle teardown to be certain.
//

import UIKit

@MainActor
enum ScreenAwake {
    private static var holds = 0

    /// Take a hold. Balance every call with `release()`.
    static func acquire() {
        holds += 1
        apply()
    }

    static func release() {
        holds = max(0, holds - 1)
        apply()
    }

    /// Drop every hold — for teardown paths that can't guarantee balance.
    static func releaseAll() {
        holds = 0
        apply()
    }

    /// Exposed for tests: the interface should never be left on by accident.
    static var isHeld: Bool { holds > 0 }

    private static func apply() {
        UIApplication.shared.isIdleTimerDisabled = holds > 0
    }
}
