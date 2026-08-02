//
//  TicketItinerary.swift
//  Jeeves
//
//  Turning a parsed ticket into a trip — and refusing to when the numbers
//  don't add up.
//
//  THE DURATION CHECK — AND EXACTLY WHAT IT PROVES
//
//  A ticket prints the local departure, the local arrival AND the duration.
//  Converting both endpoints to UTC and comparing the elapsed time to the
//  printed duration catches a class of timezone error for free.
//
//  It is important to be precise about which class, because an earlier version
//  of this comment claimed far more than the arithmetic delivers. Elapsed UTC
//  equals (arriveLocal − departLocal) − (offset_to − offset_from). The check
//  therefore constrains ONE quantity: the DIFFERENCE between the two offsets.
//  It says nothing about either zone on its own. Concretely:
//
//    • Same-zone legs are not checked at all. The difference is zero for every
//      possible assignment, so a Bengaluru→Delhi leg validates against any
//      pair of same-offset zones. Nine of this directory's airports are
//      Asia/Kolkata, so most domestic flights get no verification here.
//    • A wrong zone with the same offset is invisible — Asia/Colombo for
//      Asia/Kolkata, Asia/Makassar for Asia/Singapore.
//    • Correlated errors cancel: any pair preserving the offset difference
//      passes.
//
//  What it does catch is a wrong zone that changes the offset difference on a
//  cross-zone leg — including reading BLR as UTC+8, which makes leg 1 compute
//  7h 05m against a printed 4h 35m. (Not 1h 35m: a larger origin offset moves
//  the departure EARLIER in UTC, so the leg looks longer. The original comment
//  had the direction backwards, which is what happens when nobody runs the
//  number.)
//
//  So `verified` is recorded per leg and "unverifiable" is a first-class
//  outcome rather than silence — the same rule the airport directory follows
//  for an unknown code.
//
//  Everything here is pure. No SwiftData, no network, no UIKit — so the whole
//  thing is testable against the real ticket as a fixture.
//

import Foundation

// MARK: - What the extractor hands over

/// One flight, exactly as printed. Times are LOCAL to their own airport and
/// carry no offset, which is why `from`/`to` must resolve to real zones before
/// any of this means anything.
struct TicketLeg: Equatable, Sendable {
    var flightNumber: String
    var carrier: String
    var from: String              // IATA
    var to: String                // IATA
    var departLocal: DateComponents   // y/m/d/h/m in `from`'s zone
    var arriveLocal: DateComponents   // y/m/d/h/m in `to`'s zone
    var printedMinutes: Int?      // the duration the ticket states, if any
    var fromTerminal: String?     // usually absent on the ticket; filled from the API
    var toTerminal: String?
}

/// Booking-level facts. `bookedBy` is the agent who issued the ticket, kept
/// deliberately apart from the traveller: on a disruption it is the most
/// useful phone number on the screen, and treating it as the user's own
/// contact was the obvious way to get that wrong.
struct TicketBooking: Equatable, Sendable {
    var reference: String?
    var airlineReference: String?
    var passengerNames: [String] = []
    var bookedByName: String?
    var bookedByPhone: String?
}

// MARK: - What the day-to-day model needs

/// A gap between two legs, once classified.
enum LayoverKind: String, Equatable, Sendable {
    case connection   // you stay airside; not a stay
    case stay         // you leave the airport; this is somewhere you're going
}

struct Layover: Equatable, Sendable {
    var at: String                // IATA
    var kind: LayoverKind
    var minutes: Int
    var changesTerminal: Bool?    // nil when either terminal is unknown

    /// Nights the gap spans, which is what actually separates a connection
    /// from a stay — six daytime hours in an airport is not a visit.
    var isOvernight: Bool { minutes >= LayoverRules.overnightMinutes }
}

enum LayoverRules {
    /// A gap at or beyond this is a stay. Chosen as "long enough that you
    /// would leave the airport and sleep somewhere", not as a round number.
    static let overnightMinutes = 10 * 60

    static func classify(minutes: Int) -> LayoverKind {
        minutes >= overnightMinutes ? .stay : .connection
    }
}

// MARK: - The validated result

struct ResolvedLeg: Equatable, Sendable {
    var leg: TicketLeg
    var departUTC: Date
    var arriveUTC: Date
    var fromZoneID: String
    var toZoneID: String
    /// Whether the printed duration actually constrained this leg's zones.
    /// False when no duration was printed, and false for a same-zone leg where
    /// the check is arithmetically vacuous. A caller that wants to say "these
    /// times are verified" must read this rather than assume.
    var zonesVerified: Bool = false

    var elapsedMinutes: Int { Int(arriveUTC.timeIntervalSince(departUTC) / 60) }
    var fromName: String { AirportDirectory.name(leg.from) }
    var toName: String { AirportDirectory.name(leg.to) }
}

struct ResolvedItinerary: Equatable, Sendable {
    var legs: [ResolvedLeg]
    var layovers: [Layover]
    var booking: TicketBooking

    /// Trip window in the traveller's home zone — the first departure's day
    /// through the last arrival's day.
    var startUTC: Date? { legs.first?.departUTC }
    var endUTC: Date? { legs.last?.arriveUTC }

    /// Every gap the traveller actually spends somewhere.
    var stays: [Layover] { layovers.filter { $0.kind == .stay } }
    var connections: [Layover] { layovers.filter { $0.kind == .connection } }
}

// MARK: - Problems

enum ItineraryProblem: Equatable, Sendable {
    case unknownAirport(String)
    case unreadableTime(flight: String, which: String)
    case durationMismatch(flight: String, printed: Int, computed: Int)
    case arrivesBeforeDeparts(flight: String)
    case legsOutOfOrder(earlier: String, later: String)
    case brokenChain(landed: String, departed: String, after: String)
    case impossibleConnection(at: String, minutes: Int)
    case noLegs

    /// Whether this stops the import outright. A mismatch means a zone is
    /// wrong somewhere and every downstream time is untrustworthy; a tight
    /// connection is the airline's problem to explain, not a parse failure.
    var isFatal: Bool {
        switch self {
        case .unknownAirport, .unreadableTime, .durationMismatch,
             .arrivesBeforeDeparts, .legsOutOfOrder, .brokenChain, .noLegs:
            return true
        case .impossibleConnection:
            return false
        }
    }

    var message: String {
        switch self {
        case .unknownAirport(let code):
            return "I don't know the airport \(code), so I can't place its times on a clock."
        case .unreadableTime(let flight, let which):
            return "Couldn't read the \(which) time for \(flight)."
        case .durationMismatch(let flight, let printed, let computed):
            return "\(flight) says \(fmt(printed)) but its times work out to \(fmt(computed)) — one of the airports' clocks must be wrong, so I've stopped."
        case .arrivesBeforeDeparts(let flight):
            return "\(flight) arrives before it departs."
        case .legsOutOfOrder(let a, let b):
            return "\(b) starts before \(a) has landed."
        case .brokenChain(let landed, let departed, let after):
            return "\(after) lands at \(landed) but the next flight leaves from \(departed) — a leg is missing."
        case .impossibleConnection(let at, let minutes):
            return "Only \(fmt(minutes)) at \(at) between flights."
        case .noLegs:
            return "No flights found in this ticket."
        }
    }

    private func fmt(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m) min"
    }
}

// MARK: - Resolution

enum TicketItinerary {

    /// Minutes below which a connection is flagged. Not a hard floor — the
    /// airline sold it — but worth surfacing while a booking can still change.
    static let tightConnectionMinutes = 90

    /// How far a computed duration may drift from the printed one before the
    /// import stops. One minute absorbs rounding on the ticket; anything more
    /// means a zone is wrong, and every zone error is a whole number of
    /// half-hours, so this can be strict without being brittle.
    static let durationToleranceMinutes = 2

    /// Resolves printed local times into real instants, then checks the
    /// ticket against itself. Returns the itinerary (when it can) alongside
    /// every problem found — the caller decides what to show and what blocks.
    static func resolve(legs: [TicketLeg],
                        booking: TicketBooking = TicketBooking()) -> (itinerary: ResolvedItinerary?, problems: [ItineraryProblem]) {
        guard !legs.isEmpty else { return (nil, [.noLegs]) }

        var problems: [ItineraryProblem] = []
        var resolved: [ResolvedLeg] = []

        for leg in legs {
            guard let fromZone = AirportDirectory.timeZone(leg.from) else {
                problems.append(.unknownAirport(leg.from)); continue
            }
            guard let toZone = AirportDirectory.timeZone(leg.to) else {
                problems.append(.unknownAirport(leg.to)); continue
            }
            guard let dep = instant(from: leg.departLocal, in: fromZone) else {
                problems.append(.unreadableTime(flight: leg.flightNumber, which: "departure")); continue
            }
            guard let arr = instant(from: leg.arriveLocal, in: toZone) else {
                problems.append(.unreadableTime(flight: leg.flightNumber, which: "arrival")); continue
            }
            guard arr > dep else {
                problems.append(.arrivesBeforeDeparts(flight: leg.flightNumber)); continue
            }

            let computed = Int(arr.timeIntervalSince(dep) / 60)
            if let printed = leg.printedMinutes,
               abs(printed - computed) > durationToleranceMinutes {
                problems.append(.durationMismatch(flight: leg.flightNumber,
                                                  printed: printed, computed: computed))
                continue
            }

            // The check only proves something when a duration was printed AND
            // the two zones differ at this instant. Same offset means the
            // comparison is satisfied by every possible assignment.
            let offsetsDiffer = fromZone.secondsFromGMT(for: dep) != toZone.secondsFromGMT(for: arr)
            let verified = leg.printedMinutes != nil && offsetsDiffer

            resolved.append(ResolvedLeg(leg: leg, departUTC: dep, arriveUTC: arr,
                                        fromZoneID: fromZone.identifier,
                                        toZoneID: toZone.identifier,
                                        zonesVerified: verified))
        }

        guard resolved.count == legs.count else { return (nil, problems) }

        // Chronology across the whole itinerary, in UTC — the only frame in
        // which legs on three different clocks can be compared at all.
        for (a, b) in zip(resolved, resolved.dropFirst()) where b.departUTC < a.arriveUTC {
            problems.append(.legsOutOfOrder(earlier: a.leg.flightNumber, later: b.leg.flightNumber))
        }

        // The chain must actually join up. Chronology alone let a DROPPED leg
        // through: BLR→SIN followed by CGK→DPS resolved cleanly and invented a
        // "connection at SIN" the traveller never makes. Losing a leg is a
        // realistic extraction failure, so it gets its own check.
        for (a, b) in zip(resolved, resolved.dropFirst())
        where a.leg.to.uppercased() != b.leg.from.uppercased() {
            problems.append(.brokenChain(landed: a.leg.to, departed: b.leg.from,
                                         after: a.leg.flightNumber))
        }
        guard !problems.contains(where: \.isFatal) else { return (nil, problems) }

        let layovers = gaps(between: resolved)
        for gap in layovers where gap.kind == .connection && gap.minutes < tightConnectionMinutes {
            problems.append(.impossibleConnection(at: gap.at, minutes: gap.minutes))
        }

        return (ResolvedItinerary(legs: resolved, layovers: layovers, booking: booking), problems)
    }

    /// The gaps between consecutive legs, classified.
    static func gaps(between legs: [ResolvedLeg]) -> [Layover] {
        zip(legs, legs.dropFirst()).map { a, b in
            let minutes = max(0, Int(b.departUTC.timeIntervalSince(a.arriveUTC) / 60))
            let changes: Bool?
            if let landed = a.leg.toTerminal, let leaves = b.leg.fromTerminal {
                changes = landed != leaves
            } else {
                // Unknown is NOT "same terminal". Claiming a transfer is fine
                // when it might be a train ride away is the confident-zero
                // mistake in another costume.
                changes = nil
            }
            return Layover(at: a.leg.to,
                           kind: LayoverRules.classify(minutes: minutes),
                           minutes: minutes,
                           changesTerminal: changes)
        }
    }

    /// A local wall-clock reading, placed on a real zone.
    static func instant(from parts: DateComponents, in zone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var c = parts
        c.timeZone = zone
        c.second = 0
        guard c.year != nil, c.month != nil, c.day != nil,
              c.hour != nil, c.minute != nil else { return nil }
        return cal.date(from: c)
    }

    // MARK: Human formatting

    /// "3h 00m" / "42 min" — the two shapes the UI needs, and the only two.
    static func durationLabel(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m) min" }
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }
}
