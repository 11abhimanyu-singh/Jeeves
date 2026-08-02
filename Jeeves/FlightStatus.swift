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
    /// Set once the aircraft actually leaves. This is the terminal condition
    /// for watching: there is nothing further to tell anyone, and continuing
    /// to poll a departed flight is pure battery.
    var actualDeparture: Date? = nil
    /// When the provider last knew this to be true.
    var observedAt: Date

    nonisolated var hasDeparted: Bool { actualDeparture != nil }

    /// Floor, not truncation. `Int(_:)` rounds toward zero, so a 119-second
    /// early re-time read as −1 minute instead of −2 — wrong in the direction
    /// that matters now that a flight brought forward is actionable.
    nonisolated var delayMinutes: Int {
        Int(floor(estimatedDeparture.timeIntervalSince(scheduledDeparture) / 60))
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
    nonisolated func status(flightNumber: String, departingOn day: Date) async throws -> FlightStatusReport {
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
    /// Gone. Watching stops here.
    case departed(at: Date)

    nonisolated var isActionable: Bool {
        if case .lateUndecided = self { return true }
        if case .cancelled = self { return true }
        return false
    }
}

/// A leave-by the user confirmed, and the delay it was confirmed FOR.
///
/// Recording only the new time was not enough: a decision taken at 60 minutes
/// late kept applying when the flight slipped to 300, so the row showed a
/// leave-by four hours wrong and had stopped asking. A decision covers the
/// delay it was made for, give or take.
struct LeaveByDecision: Equatable, Sendable {
    var leaveBy: Date
    var forDelayMinutes: Int
    /// How much further the flight may slip before the decision is re-opened.
    var toleranceMinutes: Int = 10

    nonisolated func covers(delayMinutes: Int) -> Bool {
        abs(delayMinutes - forDelayMinutes) <= toleranceMinutes
    }
}

enum FlightWatch {

    /// How long before departure the app starts caring. Outside this, a delay
    /// is not actionable and polling is noise — for a September flight in
    /// August there is nothing to say.
    nonisolated static let windowHours = 12

    /// A delay under this is not worth a notification: it is inside the noise
    /// of getting to an airport, and airlines re-time by a few minutes
    /// constantly. Still shown on the journey page; just doesn't interrupt.
    nonisolated static let notifiableDelayMinutes = 20

    /// A check older than this, inside the watch window, is stale.
    nonisolated static let freshnessMinutes = 90

    /// Resolves the state. Pure, so every branch is testable without a clock
    /// or a network.
    ///
    /// - Parameters:
    ///   - report: last successful reading, if any
    ///   - scheduledDeparture: as sold, used to decide whether to watch at all
    ///   - decidedLeaveBy: set once the user has confirmed a new leave-by for
    ///     THIS delay — passing it is what moves `lateUndecided` to settled
    ///   - now: injected
    nonisolated static func state(report: FlightStatusReport?,
                      scheduledDeparture: Date,
                      decision: LeaveByDecision? = nil,
                      now: Date = Date()) -> FlightWatchState {

        // Departed and cancelled are both checked BEFORE the watch window.
        // Airlines cancel days ahead, and that is the one fact worth knowing
        // early — gating it behind a 12-hour window hid it while it was most
        // useful. Departure is terminal: nothing after it changes.
        if let report, !isFutureDated(report, now: now) {
            if let off = report.actualDeparture { return .departed(at: off) }
            if report.isCancelled { return .cancelled(observedAt: report.observedAt) }
        }

        let windowOpens = scheduledDeparture.addingTimeInterval(-Double(windowHours) * 3600)
        if now < windowOpens {
            return .notYetWatching(from: windowOpens)
        }

        guard let report else {
            // Inside the window with nothing to show is exactly the case that
            // must not read as fine.
            return .stale(lastSuccess: nil)
        }

        // Age is checked in BOTH directions. A reading stamped in the future —
        // provider clock skew, or a zone bug parsing observedAt — used to slip
        // past a one-sided `age > freshness` test and report a green state,
        // which is the precise failure this file exists to prevent.
        let age = now.timeIntervalSince(report.observedAt) / 60
        if age > Double(freshnessMinutes) || age < -Double(clockSkewToleranceMinutes) {
            return .stale(lastSuccess: age < 0 ? nil : report.observedAt)
        }

        let delay = report.delayMinutes

        // A flight that moved EARLIER is not "on time" — it is the one case
        // where the existing leave-by is dangerously late. It needs the same
        // decision as a delay, in the opposite direction.
        guard delay != 0 else { return .onTime(observedAt: report.observedAt) }

        // A decision settles ONE delay. If the flight has since slipped further
        // the decision no longer covers it, so it goes back to asking rather
        // than displaying a leave-by that matches an older, smaller delay.
        if let decision, decision.covers(delayMinutes: delay) {
            return .lateSettled(minutes: delay, leaveBy: decision.leaveBy)
        }
        return .lateUndecided(minutes: delay, observedAt: report.observedAt)
    }

    /// Guards against a provider stamping a reading in the future.
    nonisolated static let clockSkewToleranceMinutes = 5

    nonisolated static func isFutureDated(_ report: FlightStatusReport, now: Date) -> Bool {
        now.timeIntervalSince(report.observedAt) / 60 < -Double(clockSkewToleranceMinutes)
    }

    /// Whether a delay is worth interrupting someone for.
    nonisolated static func shouldNotify(delayMinutes: Int) -> Bool {
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

    nonisolated var shiftMinutes: Int { Int(floor(proposed.timeIntervalSince(current) / 60)) }

    /// True when the proposed leave-by has already passed. A proposal to leave
    /// at 18:10 delivered at 22:35 is not advice — the UI has to say so rather
    /// than render a time that quietly means "you should already be gone".
    nonisolated func isAlreadyPast(now: Date) -> Bool { proposed < now }
}

enum LeaveByRevision {

    /// Builds the proposal for a delayed flight.
    ///
    /// `journeyMinutes` is passed in rather than derived: the caller measures
    /// it for the NEW departure time, and whether that measurement succeeded
    /// is recorded honestly on the proposal.
    nonisolated static func propose(currentLeaveBy: Date,
                        report: FlightStatusReport,
                        bufferMinutes: Int,
                        journeyMinutes: Int,
                        journeyRemeasured: Bool) -> LeaveByProposal? {
        // A cancelled flight has no leave-by to propose. Offering one would be
        // the app asserting a journey it knows is not happening.
        guard !report.isCancelled else { return nil }
        let delay = report.delayMinutes
        // Non-zero in EITHER direction: a flight brought forward needs a new
        // leave-by just as much as a delayed one, and more urgently.
        guard delay != 0 else { return nil }
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
    nonisolated static func idleMinutesIfUnchanged(currentLeaveBy: Date,
                                       journeyMinutes: Int,
                                       report: FlightStatusReport) -> Int {
        let arriveAtAirport = currentLeaveBy.addingTimeInterval(Double(journeyMinutes) * 60)
        return max(0, Int(report.estimatedDeparture.timeIntervalSince(arriveAtAirport) / 60))
    }
}
