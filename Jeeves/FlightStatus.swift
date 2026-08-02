//
//  FlightStatus.swift
//  Jeeves
//
//  Whether a flight is late, and what the app is allowed to do about it.
//
//  THE RULE THIS FILE EXISTS TO ENFORCE
//
//  A delay is a fact Jeeves reports. A leave-by is a commitment only the user
//  changes. Those are different things and the code keeps them apart: nothing
//  here mutates a leave-by. It computes what the new one WOULD be and hands
//  that over as a proposal, because leaving three hours later is not obviously
//  right — the traffic is different, and going early to wait airside is a real
//  choice the app cannot make for anyone.
//
//  The second rule is about silence. A status line that reads "on time" from a
//  seven-hour-old check is the same failure as an export that reported
//  "written" and meant "delivered". So staleness is part of the state, not a
//  detail the UI may forget.
//

import Foundation

// MARK: - What a provider returns

struct FlightStatusReport: Equatable, Sendable {
    var flightNumber: String
    /// As sold.
    var scheduledDeparture: Date
    /// Best current estimate — equal to scheduled when on time.
    var estimatedDeparture: Date
    var scheduledArrival: Date?
    var estimatedArrival: Date?
    var departureTerminal: String?
    var arrivalTerminal: String?
    var isCancelled: Bool = false
    /// When the provider last knew this to be true.
    var observedAt: Date

    var delayMinutes: Int {
        Int(estimatedDeparture.timeIntervalSince(scheduledDeparture) / 60)
    }
}

/// Anything that can answer "is this flight late". Behind a protocol so the
/// whole feature — model, states, UI, tests — works with no key configured
/// and no network, which is also how it behaves on a plane.
protocol FlightStatusProviding: Sendable {
    func status(flightNumber: String, departingOn day: Date) async throws -> FlightStatusReport
}

/// The stand-in used until a provider is chosen. It does not invent a status;
/// it says it has none, which is the honest answer and keeps every downstream
/// state exercised.
struct UnconfiguredFlightStatusProvider: FlightStatusProviding {
    struct NotConfigured: LocalizedError {
        var errorDescription: String? { "No flight-status service is set up yet." }
    }
    func status(flightNumber: String, departingOn day: Date) async throws -> FlightStatusReport {
        throw NotConfigured()
    }
}

// MARK: - The state the line renders

/// Exactly the states the status line has to hold. Anything the UI shows must
/// come from one of these — the point of naming them here is that "on time"
/// cannot be reached by accident.
enum FlightWatchState: Equatable, Sendable {
    /// Too far out to be watching. Carries when watching begins.
    case notYetWatching(from: Date)
    /// Watched and on schedule, as of `observedAt`.
    case onTime(observedAt: Date)
    /// Late, and the user has not said what to do about the leave-by.
    case lateUndecided(minutes: Int, observedAt: Date)
    /// Late, and the leave-by has been settled — delay stays visible, the
    /// call to action goes away so it stops nagging about a handled thing.
    case lateSettled(minutes: Int, leaveBy: Date)
    /// A check was expected and hasn't succeeded. Never rendered as on time.
    case stale(lastSuccess: Date?)
    case cancelled(observedAt: Date)

    var isActionable: Bool {
        if case .lateUndecided = self { return true }
        if case .cancelled = self { return true }
        return false
    }
}

enum FlightWatch {

    /// How long before departure the app starts caring. Outside this, a delay
    /// is not actionable and polling is noise — for a September flight in
    /// August there is nothing to say.
    static let windowHours = 12

    /// A delay under this is not worth a notification: it is inside the noise
    /// of getting to an airport, and airlines re-time by a few minutes
    /// constantly. Still shown on the journey page; just doesn't interrupt.
    static let notifiableDelayMinutes = 20

    /// A check older than this, inside the watch window, is stale.
    static let freshnessMinutes = 90

    /// Resolves the state. Pure, so every branch is testable without a clock
    /// or a network.
    ///
    /// - Parameters:
    ///   - report: last successful reading, if any
    ///   - scheduledDeparture: as sold, used to decide whether to watch at all
    ///   - decidedLeaveBy: set once the user has confirmed a new leave-by for
    ///     THIS delay — passing it is what moves `lateUndecided` to settled
    ///   - now: injected
    static func state(report: FlightStatusReport?,
                      scheduledDeparture: Date,
                      decidedLeaveBy: Date? = nil,
                      now: Date = Date()) -> FlightWatchState {

        let windowOpens = scheduledDeparture.addingTimeInterval(-Double(windowHours) * 3600)
        if now < windowOpens {
            return .notYetWatching(from: windowOpens)
        }

        guard let report else {
            // Inside the window with nothing to show is exactly the case that
            // must not read as fine.
            return .stale(lastSuccess: nil)
        }

        if report.isCancelled { return .cancelled(observedAt: report.observedAt) }

        let age = now.timeIntervalSince(report.observedAt) / 60
        if age > Double(freshnessMinutes) {
            return .stale(lastSuccess: report.observedAt)
        }

        let delay = report.delayMinutes
        guard delay > 0 else { return .onTime(observedAt: report.observedAt) }

        if let decidedLeaveBy {
            return .lateSettled(minutes: delay, leaveBy: decidedLeaveBy)
        }
        return .lateUndecided(minutes: delay, observedAt: report.observedAt)
    }

    /// Whether a delay is worth interrupting someone for.
    static func shouldNotify(delayMinutes: Int) -> Bool {
        delayMinutes >= notifiableDelayMinutes
    }
}

// MARK: - The proposal

/// What the leave-by WOULD become. Never applied by anything in this file.
struct LeaveByProposal: Equatable, Sendable {
    var current: Date
    var proposed: Date
    var delayMinutes: Int
    /// True when the journey time was re-measured for the new departure rather
    /// than the old number being slid along. Traffic at 20:50 is not traffic
    /// at 17:50, and a shifted estimate wearing a measured face is the exact
    /// thing the `~` convention exists to prevent.
    var journeyRemeasured: Bool
    var journeyMinutes: Int

    var shiftMinutes: Int { Int(proposed.timeIntervalSince(current) / 60) }
}

enum LeaveByRevision {

    /// Builds the proposal for a delayed flight.
    ///
    /// `journeyMinutes` is passed in rather than derived: the caller measures
    /// it for the NEW departure time, and whether that measurement succeeded
    /// is recorded honestly on the proposal.
    static func propose(currentLeaveBy: Date,
                        report: FlightStatusReport,
                        bufferMinutes: Int,
                        journeyMinutes: Int,
                        journeyRemeasured: Bool) -> LeaveByProposal? {
        let delay = report.delayMinutes
        guard delay > 0 else { return nil }
        let atAirport = report.estimatedDeparture
            .addingTimeInterval(-Double(bufferMinutes) * 60)
        let proposed = atAirport.addingTimeInterval(-Double(journeyMinutes) * 60)
        return LeaveByProposal(current: currentLeaveBy,
                               proposed: proposed,
                               delayMinutes: delay,
                               journeyRemeasured: journeyRemeasured,
                               journeyMinutes: journeyMinutes)
    }

    /// How long you'd wait at the terminal if you kept the current leave-by.
    /// The consequence of doing nothing, which the user is entitled to see
    /// before choosing to do nothing.
    static func idleMinutesIfUnchanged(currentLeaveBy: Date,
                                       journeyMinutes: Int,
                                       report: FlightStatusReport) -> Int {
        let arriveAtAirport = currentLeaveBy.addingTimeInterval(Double(journeyMinutes) * 60)
        return max(0, Int(report.estimatedDeparture.timeIntervalSince(arriveAtAirport) / 60))
    }
}
