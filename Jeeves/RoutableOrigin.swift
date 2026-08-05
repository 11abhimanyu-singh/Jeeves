//
//  RoutableOrigin.swift
//  Jeeves
//
//  One question: is this string something a routing API can start from?
//
//  With no saved home, two call sites fell back to the literal word "Home" and
//  POSTed it to the Routes API as an origin. Google geocodes it to whatever it
//  likes — a shop of that name, a suburb, a different country — and the minutes
//  that came back were rendered as a MEASURED leave-by, indistinguishable from
//  a real one. A wrong number in that slot is worse than an empty one: the slot
//  exists precisely so it can be trusted without checking.
//
//  So the refusal belongs here, at the source, rather than at each place that
//  displays a result. Pure, so the list of words that aren't addresses can be
//  argued with in a test.
//

import Foundation

enum RoutableOrigin {

    /// Names the app uses for places that mean something to the user and
    /// nothing to a map. Lowercased; compared after trimming.
    ///
    /// Deliberately short. Every entry has to be a word that is ONLY ever a
    /// label — "home" qualifies, "Bangalore" does not, and a street address
    /// that happens to contain the word "home" is untouched because the match
    /// is on the whole string.
    nonisolated static let placeholders: Set<String> = [
        "home", "house", "my home", "my house",
        "work", "office", "my work", "my office",
    ]

    nonisolated static func isPlaceholder(_ candidate: String) -> Bool {
        placeholders.contains(
            candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The address to route from, or nil when there isn't one.
    ///
    /// nil is the useful answer: it lets the caller say "I need your home
    /// address" and offer to collect it, instead of showing a number derived
    /// from a guess. Callers must not substitute a default for nil — that is
    /// the bug this exists to prevent.
    nonisolated static func address(_ candidate: String?) -> String? {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !isPlaceholder(trimmed) else { return nil }
        return trimmed
    }

    /// What to show where a leave-by would have gone. Never a time.
    static let missingHomeMessage = "Leave-by needs your home address"

    /// The same, naming the label that could not be resolved. "Leave-by needs
    /// your home address" was shown when the unresolved place was Work, which
    /// sends the user to correct something that was never wrong.
    nonisolated static func missingAddressMessage(for label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return missingHomeMessage }
        return isPlaceholder(trimmed) && trimmed.lowercased().hasPrefix("home")
            ? missingHomeMessage
            : "Leave-by needs an address for \(trimmed)"
    }
}
