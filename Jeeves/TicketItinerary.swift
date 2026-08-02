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
    /// Whether the gap actually spans a night where it happens.
    var isOvernight: Bool = false
}

enum LayoverRules {
    /// The hour that means "you slept somewhere". A gap containing local 03:00
    /// at the layover airport is a night, whatever its length.
    nonisolated static let deepNightHour = 3

    /// Beyond this a gap is a stay regardless of clock — a day and a half in a
    /// terminal is not a connection even if it dodges the small hours.
    nonisolated static let unconditionalStayMinutes = 14 * 60

    /// Whether the gap contains local 03:00 at the place it happens.
    ///
    /// The old rule was "10 hours or more", which was neither overnight nor
    /// accurate in either direction: a 22:00→05:00 gap where you would take a
    /// hotel counted as a connection, and eleven daytime hours airside counted
    /// as a stay. Length was standing in for a question about the clock, so
    /// now it asks the clock.
    nonisolated static func spansNight(from start: Date, minutes: Int,
                                       in zone: TimeZone) -> Bool {
        guard minutes > 0 else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let end = start.addingTimeInterval(Double(minutes) * 60)
        // Walk each local 03:00 from the day the gap starts and see if one
        // falls inside it. At most a couple of iterations for any real gap,
        // and correct across DST because it re-derives each night's 03:00.
        var probeDay = cal.startOfDay(for: start)
        while probeDay <= end {
            if let night = cal.date(bySettingHour: deepNightHour, minute: 0, second: 0,
                                    of: probeDay, matchingPolicy: .nextTime),
               night > start, night < end {
                return true
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: probeDay) else { break }
            probeDay = next
        }
        return false
    }

    nonisolated static func classify(minutes: Int, spansNight: Bool) -> LayoverKind {
        (spansNight || minutes >= unconditionalStayMinutes) ? .stay : .connection
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

    nonisolated var elapsedMinutes: Int { Int(arriveUTC.timeIntervalSince(departUTC) / 60) }
    nonisolated var fromName: String { AirportDirectory.name(leg.from) }
    nonisolated var toName: String { AirportDirectory.name(leg.to) }
}

struct ResolvedItinerary: Equatable, Sendable {
    var legs: [ResolvedLeg]
    var layovers: [Layover]
    var booking: TicketBooking

    /// Trip window in the traveller's home zone — the first departure's day
    /// through the last arrival's day.
    nonisolated var startUTC: Date? { legs.first?.departUTC }
    nonisolated var endUTC: Date? { legs.last?.arriveUTC }

    /// Every gap the traveller actually spends somewhere.
    nonisolated var stays: [Layover] { layovers.filter { $0.kind == .stay } }
    nonisolated var connections: [Layover] { layovers.filter { $0.kind == .connection } }
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
    /// A local time the clocks jumped over (spring forward).
    case clockSkipped(flight: String, which: String)
    /// A local time that happens twice (fall back).
    case clockRepeated(flight: String, which: String)
    case noLegs

    /// Whether this stops the import outright. A mismatch means a zone is
    /// wrong somewhere and every downstream time is untrustworthy; a tight
    /// connection is the airline's problem to explain, not a parse failure.
    nonisolated var isFatal: Bool {
        switch self {
        case .unknownAirport, .unreadableTime, .durationMismatch,
             .arrivesBeforeDeparts, .legsOutOfOrder, .brokenChain, .noLegs:
            return true
        case .impossibleConnection, .clockSkipped, .clockRepeated:
            return false
        }
    }

    nonisolated var message: String {
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
        case .clockSkipped(let flight, let which):
            return "\(flight)'s \(which) time doesn't exist — the clocks go forward that morning. Times near it could be an hour out."
        case .clockRepeated(let flight, let which):
            return "\(flight)'s \(which) time happens twice that day — the clocks go back. I've taken the first; it could be an hour out."
        case .noLegs:
            return "No flights found in this ticket."
        }
    }

    nonisolated private func fmt(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m) min"
    }
}

// MARK: - Resolution

enum TicketItinerary {

    /// Minutes below which a connection is flagged. Not a hard floor — the
    /// airline sold it — but worth surfacing while a booking can still change.
    nonisolated static let tightConnectionMinutes = 90

    /// How far a computed duration may drift from the printed one before the
    /// import stops. One minute absorbs rounding on the ticket; anything more
    /// means a zone is wrong, and every zone error is a whole number of
    /// half-hours, so this can be strict without being brittle.
    nonisolated static let durationToleranceMinutes = 2

    /// Resolves printed local times into real instants, then checks the
    /// ticket against itself. Returns the itinerary (when it can) alongside
    /// every problem found — the caller decides what to show and what blocks.
    nonisolated static func resolve(legs: [TicketLeg],
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
            guard let depResolved = resolve(leg.departLocal, in: fromZone) else {
                problems.append(.unreadableTime(flight: leg.flightNumber, which: "departure")); continue
            }
            guard let arrResolved = resolve(leg.arriveLocal, in: toZone) else {
                problems.append(.unreadableTime(flight: leg.flightNumber, which: "arrival")); continue
            }
            let dep = depResolved.date
            let arr = arrResolved.date

            // A clock that jumped or repeated is reported, not swallowed. Both
            // are non-fatal: the ticket is still importable, but the leave-by
            // built from it could be an hour out and the user should know.
            for (resolution, which) in [(depResolved.resolution, "departure"),
                                        (arrResolved.resolution, "arrival")] {
                switch resolution {
                case .exact: break
                case .nonexistent:
                    problems.append(.clockSkipped(flight: leg.flightNumber, which: which))
                case .ambiguous:
                    problems.append(.clockRepeated(flight: leg.flightNumber, which: which))
                }
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
    nonisolated static func gaps(between legs: [ResolvedLeg]) -> [Layover] {
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
            let zone = TimeZone(identifier: a.toZoneID) ?? .current
            let overnight = LayoverRules.spansNight(from: a.arriveUTC, minutes: minutes, in: zone)
            return Layover(at: a.leg.to,
                           kind: LayoverRules.classify(minutes: minutes, spansNight: overnight),
                           minutes: minutes,
                           changesTerminal: changes,
                           isOvernight: overnight)
        }
    }

    /// How a local reading landed on the timeline.
    enum ClockResolution: Equatable, Sendable {
        case exact
        /// The wall time does not exist — the clocks jumped over it. Foundation
        /// silently snaps forward, so 02:30 on a spring-forward morning becomes
        /// 03:30 with no error anywhere. Reported instead.
        case nonexistent(snappedTo: Date)
        /// The wall time happens twice. Foundation always returns the FIRST,
        /// making the second unreachable — an hour of error on a leave-by, and
        /// invisible.
        case ambiguous(chosen: Date, other: Date)
    }

    /// A local wall-clock reading, placed on a real zone, with an honest
    /// account of whether that placement was unique.
    nonisolated static func resolve(_ parts: DateComponents,
                                    in zone: TimeZone) -> (date: Date, resolution: ClockResolution)? {
        guard let y = parts.year, let mo = parts.month, let d = parts.day,
              let h = parts.hour, let mi = parts.minute else { return nil }
        // Foundation is lenient: month 13 rolls into next January and day 32
        // into the following month, so an OCR slip becomes a plausible wrong
        // date rather than a rejection. Range-check first.
        guard (1...12).contains(mo), (1...31).contains(d),
              (0...23).contains(h), (0...59).contains(mi) else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var c = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: 0)
        c.timeZone = zone
        guard let date = cal.date(from: c) else { return nil }

        // Did we get back the wall time we asked for? If not, it didn't exist.
        let got = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if got.day != d || got.hour != h || got.minute != mi || got.month != mo || got.year != y {
            return (date, .nonexistent(snappedTo: date))
        }

        // An hour earlier showing the SAME wall time means this reading happens
        // twice — a fall-back morning.
        let earlier = date.addingTimeInterval(-3600)
        let earlierParts = cal.dateComponents([.hour, .minute, .day], from: earlier)
        if earlierParts.hour == h, earlierParts.minute == mi, earlierParts.day == d {
            return (earlier, .ambiguous(chosen: earlier, other: date))
        }
        // Or an hour later does — same situation, the other way round.
        let later = date.addingTimeInterval(3600)
        let laterParts = cal.dateComponents([.hour, .minute, .day], from: later)
        if laterParts.hour == h, laterParts.minute == mi, laterParts.day == d {
            return (date, .ambiguous(chosen: date, other: later))
        }

        return (date, .exact)
    }

    /// Convenience for callers that only need the instant.
    nonisolated static func instant(from parts: DateComponents, in zone: TimeZone) -> Date? {
        resolve(parts, in: zone)?.date
    }

    // MARK: Human formatting

    /// "3h 00m" / "42 min" — the two shapes the UI needs, and the only two.
    nonisolated static func durationLabel(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m) min" }
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }
}
