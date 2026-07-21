//
//  BackgroundActivity.swift
//  Jeeves
//
//  Keeps a short async operation alive when the app is backgrounded mid-flight.
//  Planning calls Claude over the network; if the user switches away while it's
//  running, iOS would normally suspend the app and tear the request down (so
//  the plan silently falls back to the offline scheduler). Wrapping the work in
//  a UIKit background-task assertion asks the system for extra time to finish.
//
//  This is best-effort: iOS grants a limited window (typically ~30s, sometimes
//  more) and calls the expiration handler if it runs out — enough for a normal
//  planning round-trip. It is NOT a guarantee for arbitrarily long work; a
//  minutes-long background would need a background URLSession instead.
//

import UIKit

@MainActor
enum BackgroundActivity {
    /// Runs `operation` under a named background-task assertion and returns its
    /// result. The assertion is always ended exactly once — when the work
    /// finishes or when iOS expires our time, whichever comes first.
    static func run<T>(_ name: String, operation: () async -> T) async -> T {
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            token.end()   // expiration handler — must end the assertion promptly
        }
        defer { token.end() }
        return await operation()
    }

    /// Holds the assertion id so both the completion path and the expiration
    /// handler end it idempotently (double-ending is a UIKit error).
    @MainActor
    private final class Token {
        var id: UIBackgroundTaskIdentifier = .invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
