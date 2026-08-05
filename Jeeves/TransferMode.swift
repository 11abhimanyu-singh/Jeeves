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
        /// sign the two ends are not connected the way we assumed. Carries the
        /// distance because "11 h" invites an argument and "11 h and 3,400 km"
        /// settles it — and because a distance we ask the API for and never
        /// read is a field mask entry pretending to be a feature.
        case tooFarToDrive(minutes: Int, kilometres: Double? = nil)
        /// The engine answered, and the answer is that there is no road. Across
        /// water, or an address it could not resolve.
        case notRoutableByRoad
        /// We never got an answer — no key, no network, nothing sent. Says
        /// nothing whatever about the world, and must never be reported as if
        /// it did: "there's no road route from Bali to Singapore" was being
        /// printed when the real cause was a missing API key.
        case couldNotAsk(GoogleMapsService.RouteFailure)
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
            : .tooFarToDrive(minutes: route.minutes, kilometres: route.kilometres)
    }

    /// The version that knows WHY there was no route. Prefer this everywhere a
    /// reason is shown to the user.
    nonisolated static func classify(_ result: Result<GoogleMapsService.Route, GoogleMapsService.RouteFailure>) -> Verdict {
        switch result {
        case .success(let route):
            return classify(route: route)
        case .failure(.noRouteFound):
            return .notRoutableByRoad
        case .failure(let other):
            return .couldNotAsk(other)
        }
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
        case .tooFarToDrive(let minutes, let km):
            let distance = km.map { " and \(Int($0.rounded())) km" } ?? ""
            return "\(from) to \(to) routes \(LeaveBy.hours(minutes))\(distance) by road. I'd assumed you were driving — how are you getting there?"
        case .notRoutableByRoad:
            return "There's no road route from \(from) to \(to). I'd assumed you were driving — how are you getting there?"
        case .couldNotAsk(let why):
            // Says what WE failed at, never what the world is like.
            switch why {
            case .noKey:
                return "I couldn't check the drive from \(from) to \(to) — there's no Maps key saved. This is still an assumed drive."
            case .unreachable, .refused:
                // No "I'll try again": nothing retries, and a promise the app
                // does not keep is its own small lie. Tapping Measure is the
                // retry, so say that.
                return "I couldn't reach Maps to check the drive from \(from) to \(to) — tap Measure to try again. This is still an assumed drive."
            case .blankEndpoint:
                return "I need an address for both ends before I can check the drive from \(from) to \(to)."
            case .noRouteFound:
                return "There's no road route from \(from) to \(to). I'd assumed you were driving — how are you getting there?"
            }
        }
    }

    /// Should we try again later? A refusal about the world is final; a failure
    /// of ours is not, and the two were being treated the same.
    nonisolated static func worthRetrying(_ verdict: Verdict) -> Bool {
        if case .couldNotAsk(let why) = verdict {
            return why != .blankEndpoint
        }
        return false
    }
}
