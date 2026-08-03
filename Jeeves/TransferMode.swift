//
//  TransferMode.swift
//  Jeeves
//
//  What may be claimed about a move between two stays.
//
//  The calendar path writes every stay-to-stay transfer as a DRIVE. That is
//  correct for Kabini → Bandipur — 99 km of Karnataka road — and wrong for
//  Bali → Singapore, and the two look identical going in: two places, two
//  dates, a handover day. The app was picking one and saying nothing.
//
//  The signal that separates them was already being thrown away. The Routes
//  request asked for `routes.duration` and nothing else, so a route that comes
//  back at eleven hours and one that doesn't come back at all were both just
//  "no minutes". Asking for distance too, and classifying the answer, turns the
//  guess into a reading — and where it stays a guess, says so.
//
//  Pure, so every threshold here can be argued with in a test rather than
//  discovered on a morning you're trying to reach an airport.
//

import Foundation

enum TransferMode {

    /// What a routing engine's answer entitles us to say.
    nonisolated enum Verdict: Sendable, Equatable {
        /// Road-routable and a plausible length. Safe to present as a drive.
        case drive(minutes: Int)
        /// Road-routable, but nobody drives this in one go. Almost always a
        /// sign the two ends are not connected the way we assumed.
        case tooFarToDrive(minutes: Int)
        /// The engine returned nothing. Across water, or an address it could
        /// not resolve — indistinguishable from here, which is the point:
        /// both mean "do not call this a drive".
        case notRoutableByRoad
    }

    /// The longest road transfer presented as a drive without asking.
    ///
    /// Ten hours. Bengaluru to Bandipur is about six on a bad day, so this
    /// clears every realistic domestic transfer while still catching a route
    /// that has quietly gone continental. It is deliberately generous: a wrong
    /// prompt costs one tap, a wrong mode costs a missed flight.
    static let plausibleDriveMinutes = 600

    nonisolated static func classify(route: GoogleMapsService.Route?) -> Verdict {
        guard let route else { return .notRoutableByRoad }
        return route.minutes <= plausibleDriveMinutes
            ? .drive(minutes: route.minutes)
            : .tooFarToDrive(minutes: route.minutes)
    }

    /// May this verdict settle an assumed mode? Only a plausible drive does.
    /// The other two leave the assumption standing AND visible, because the
    /// honest next step is a question, not a different guess.
    nonisolated static func settlesTheAssumption(_ verdict: Verdict) -> Bool {
        if case .drive = verdict { return true }
        return false
    }

    /// What to tell the user when the road answer refutes the assumption.
    nonisolated static func note(for verdict: Verdict, from: String, to: String) -> String? {
        switch verdict {
        case .drive:
            return nil
        case .tooFarToDrive(let minutes):
            return "\(from) to \(to) routes \(LeaveBy.hours(minutes)) by road. I'd assumed you were driving — how are you getting there?"
        case .notRoutableByRoad:
            return "There's no road route from \(from) to \(to). I'd assumed you were driving — how are you getting there?"
        }
    }
}
