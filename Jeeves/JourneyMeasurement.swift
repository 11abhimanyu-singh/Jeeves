//
//  JourneyMeasurement.swift
//  Jeeves
//
//  The one place a measured journey time is turned into stored state.
//
//  `acceptTravel` learned to classify a road answer before believing it — but
//  it was the only path that did. The Measure button, the segment editor's
//  Save, chat's add_journey, chat's add_stay and chat's stay re-sync all still
//  wrote `travelMinutes` straight in: an eleven-hour road answer silently
//  settled a refuted drive, a stale refutation survived a fresh measurement,
//  and none of them ever set `measuredAt`, so freshness lied on every row they
//  touched. Five paths disagreeing with one is not a rule, it is a coincidence.
//
//  The decision is pure and lives in `decide`; the mutation is one call. New
//  measuring surfaces must go through `apply` — there is no correct way to set
//  travelMinutes by hand.
//

import Foundation

enum JourneyMeasurement {

    /// What a verdict entitles us to change.
    nonisolated struct Decision: Sendable, Equatable {
        /// Minutes to store, or nil to leave the previous value alone. A real
        /// reading is kept even when it refutes the mode — throwing it away to
        /// signal doubt trades a silent wrong answer for a silent missing one.
        var minutes: Int?
        /// Does this answer settle which mode this is?
        var settlesMode: Bool
        /// What to tell the user, or nil when nothing needs saying.
        var note: String?
        /// May a leave-by notification fire off the back of this?
        ///
        /// A refuted drive still had a chain, and the chain still nudged — so
        /// the doubt reached the card and not the notification, which is the
        /// half the user actually acts on at 06:00.
        var mayNudge: Bool
    }

    nonisolated static func decide(_ verdict: TransferMode.Verdict,
                                   from: String, to: String) -> Decision {
        switch verdict {
        case .drive(let m):
            // Asks TransferMode rather than restating its rule: two places
            // deciding what settles a mode is how they drift apart.
            return Decision(minutes: m,
                            settlesMode: TransferMode.settlesTheAssumption(verdict),
                            note: nil, mayNudge: true)

        case .tooFarToDrive(let m, _):
            // Keep the reading, keep the doubt, and do NOT nudge: an unqualified
            // "leave at 05:55" for a journey we don't believe is a drive is
            // worse than silence.
            return Decision(minutes: m, settlesMode: false,
                            note: TransferMode.note(for: verdict, from: from, to: to),
                            mayNudge: false)

        case .notRoutableByRoad, .couldNotAsk:
            return Decision(minutes: nil, settlesMode: false,
                            note: TransferMode.note(for: verdict, from: from, to: to),
                            mayNudge: false)
        }
    }

    /// How a route is obtained. Injectable because chat's executor already had
    /// a seam for exactly this, and a funnel that hard-codes the network call
    /// silently removes every caller's ability to test — which is how routing
    /// four paths through one helper broke six passing chat tests.
    typealias RouteSource = @Sendable (String, String, Date) async
        -> Result<GoogleMapsService.Route, GoogleMapsService.RouteFailure>

    @Sendable
    static func liveRoute(_ from: String, _ to: String, _ departure: Date) async
        -> Result<GoogleMapsService.Route, GoogleMapsService.RouteFailure> {
        await GoogleMapsService.routeOrFailure(from: from, to: to, departure: departure)
    }

    /// Measure one segment and store exactly what the answer justifies.
    /// Returns the decision so the caller can render the note and decide
    /// whether to schedule anything.
    @discardableResult
    @MainActor
    static func apply(to segment: TravelSegment,
                      from: String, to: String,
                      departure: Date,
                      label: (from: String, to: String)? = nil,
                      now: Date = Date(),
                      route: RouteSource = liveRoute) async -> Decision {
        let result = await route(from, to, departure)
        let verdict = TransferMode.classify(result)
        let names = label ?? (from: from, to: to)
        let decision = decide(verdict, from: names.from, to: names.to)

        if let m = decision.minutes {
            segment.record(minutes: m, now: now, settlesMode: decision.settlesMode)
        }
        // Always refresh the explanation: a stale reason outlives the thing it
        // explained, and "no road route" left standing after an address is
        // added is a lie with a timestamp.
        segment.modeRefutation = decision.note ?? ""
        return decision
    }

    /// The two ends of a transfer, named for a sentence rather than a route.
    /// The label is "Kabini → Bandipur"; the places are what a person calls them.
    nonisolated static func endpoints(of label: String,
                                      fallbackFrom: String, fallbackTo: String) -> (from: String, to: String) {
        let parts = label.components(separatedBy: " → ")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return (fallbackFrom, fallbackTo)
        }
        return (parts[0], parts[1])
    }
}
