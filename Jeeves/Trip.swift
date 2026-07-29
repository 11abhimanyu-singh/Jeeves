//
//  Trip.swift
//  Jeeves
//
//  Travel mode. A Trip marks a span of days on which the planner STANDS DOWN:
//  no routine, no gym you can't reach, no commute to nowhere. In their place
//  you get anchors — when to leave, the flight, the check-in, the way home.
//
//  A TravelSegment is one journey: a flight (work backwards from its departure
//  through the airline cut-off, immigration and traffic) or a drive (work
//  backwards from a hard arrival time through the driving and any stops). The
//  arithmetic lives in LeaveBy, which is pure and unit-tested — the whole point
//  of the feature is a number you can trust at 4am in an unfamiliar airport.
//
//  All stored properties carry defaults so CloudKit mirroring stays happy.
//

import Foundation
import SwiftData

enum TravelMode: String, CaseIterable {
    case flight, drive, train

    var label: String {
        switch self {
        case .flight: return "Flight"
        case .drive:  return "Drive"
        case .train:  return "Train"
        }
    }
    var icon: String {
        switch self {
        case .flight: return "airplane"
        case .drive:  return "car.fill"
        case .train:  return "tram.fill"
        }
    }
}

@Model
final class Trip {
    var id: UUID = UUID()
    var title: String = ""
    var startDate: Date = Date.distantPast    // start of the first travel day
    var endDate: Date = Date.distantPast      // start of the LAST travel day (inclusive)
    var notes: String = ""

    init(id: UUID = UUID(), title: String, startDate: Date, endDate: Date, notes: String = "") {
        self.id = id
        self.title = title
        self.startDate = startDate.startOfDay
        self.endDate = endDate.startOfDay
        self.notes = notes
    }

    /// Does this trip put the given day in travel mode?
    nonisolated func covers(_ day: Date, calendar: Calendar = .current) -> Bool {
        let d = calendar.startOfDay(for: day)
        return d >= calendar.startOfDay(for: startDate) && d <= calendar.startOfDay(for: endDate)
    }

    var dayCount: Int {
        (Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0) + 1
    }
}

@Model
final class TravelSegment {
    var id: UUID = UUID()
    var tripID: UUID = UUID()
    var modeRaw: String = TravelMode.flight.rawValue
    var label: String = ""            // "6E 1605" or "Drive to Bhadra"

    /// Where the journey starts. Empty = the user's Home. For a leg that starts
    /// abroad this is the hotel address — which is the whole reason a segment
    /// carries its own origin instead of assuming Home.
    var fromPlace: String = ""
    var toPlace: String = ""          // airport or destination address

    /// Flights: the scheduled departure. Drives: ignored.
    /// ALWAYS an absolute instant — the wall-clock the user typed is
    /// interpreted in `fromTimeZone`, so "19:40 in Singapore" means the same
    /// moment whether it was entered from Bengaluru or from the hotel lobby.
    var departAt: Date = Date.distantPast
    /// Drives: the hard "must be there by". Flights: nil.
    var arriveBy: Date? = nil
    /// Flights: scheduled arrival, shown in the destination's zone.
    var arriveAt: Date? = nil

    /// IANA zones for each end. Empty = the device's zone (the common case:
    /// a drive that starts and ends at home).
    var fromTimeZoneID: String = ""
    var toTimeZoneID: String = ""

    // Assumptions — every one is editable, and the UI says so.
    var checkInMinutes: Int = 180     // airline cut-off before departure
    var securityMinutes: Int = 30     // immigration + security once inside
    var bufferMinutes: Int = 20       // the user's own slack
    var stopMinutes: Int = 0          // drives: fuel, breakfast, rest
    /// Cached journey time. Measured by Maps when possible; otherwise entered.
    var travelMinutes: Int = 0
    var travelIsEstimated: Bool = true   // false once Maps has priced it

    init(id: UUID = UUID(), tripID: UUID, mode: TravelMode, label: String,
         fromPlace: String = "", toPlace: String = "",
         departAt: Date = .distantPast, arriveBy: Date? = nil, arriveAt: Date? = nil,
         fromTimeZoneID: String = "", toTimeZoneID: String = "",
         checkInMinutes: Int = 180, securityMinutes: Int = 30, bufferMinutes: Int = 20,
         stopMinutes: Int = 0, travelMinutes: Int = 0, travelIsEstimated: Bool = true) {
        self.id = id
        self.tripID = tripID
        self.modeRaw = mode.rawValue
        self.label = label
        self.fromPlace = fromPlace
        self.toPlace = toPlace
        self.departAt = departAt
        self.arriveBy = arriveBy
        self.arriveAt = arriveAt
        self.fromTimeZoneID = fromTimeZoneID
        self.toTimeZoneID = toTimeZoneID
        self.checkInMinutes = checkInMinutes
        self.securityMinutes = securityMinutes
        self.bufferMinutes = bufferMinutes
        self.stopMinutes = stopMinutes
        self.travelMinutes = travelMinutes
        self.travelIsEstimated = travelIsEstimated
    }

    var mode: TravelMode {
        get { TravelMode(rawValue: modeRaw) ?? .flight }
        set { modeRaw = newValue.rawValue }
    }

    var fromTimeZone: TimeZone { TimeZone(identifier: fromTimeZoneID) ?? .current }
    var toTimeZone: TimeZone { TimeZone(identifier: toTimeZoneID) ?? .current }

    /// The day this segment belongs to — its departure for a flight, its
    /// arrival deadline for a drive — reckoned WHERE THE JOURNEY STARTS. A
    /// 00:30 departure from Singapore belongs to that Singapore day, not to
    /// whatever day it happens to be back home.
    /// The day this journey belongs to on the planner: the day you LEAVE, on
    /// the origin's clock. A two-day return drive arriving Tuesday shows on
    /// Sunday — the day the user must actually act — not on the arrival day
    /// (which for a long drive can sit outside the trip window entirely,
    /// making the journey invisible). A red-eye departing 00:30 belongs to
    /// the evening you leave for the airport, the day before.
    var day: Date {
        let instant = LeaveBy.plan(for: self)?.leaveAt
            ?? (mode == .drive ? (arriveBy ?? departAt) : departAt)
        return Self.deviceDay(of: instant, in: fromTimeZone)
    }

    /// The day this journey ENDS, on the destination's clock — nil when no
    /// arrival is known. With `day`, this brackets the journey for trip-window
    /// checks (a two-day drive can land after the calendar event ends).
    var arrivalDay: Date? {
        let instant = mode == .drive ? arriveBy : (arriveAt ?? (departAt == .distantPast ? nil : departAt))
        return instant.map { Self.deviceDay(of: $0, in: toTimeZone) }
    }

    /// The DEVICE-calendar date carrying the instant's nominal day in `zone` —
    /// so "12 Oct in Kathmandu" compares equal to the planner's "12 Oct" even
    /// though the two midnights are 15 minutes apart. Every day-of-trip
    /// comparison in the app runs on device days; this keeps foreign journeys
    /// on the same footing.
    nonisolated static func deviceDay(of instant: Date, in zone: TimeZone) -> Date {
        var origin = Calendar.current
        origin.timeZone = zone
        let comps = origin.dateComponents([.year, .month, .day], from: instant)
        return Calendar.current.date(from: comps) ?? Calendar.current.startOfDay(for: instant)
    }
}

/// One place you're in for a stretch of the trip. Two stays are what make a
/// multi-leg journey legible: Bali 3–10 Sep, Singapore 11–14 Sep. A stay's
/// address is also the ORIGIN of the journey that leaves it — which is how the
/// ride to the airport gets priced from your hotel rather than from home.
@Model
final class TripStay {
    var id: UUID = UUID()
    var tripID: UUID = UUID()
    var place: String = ""            // "Bali"
    var address: String = ""          // the hotel, once known
    var lat: Double? = nil
    var lng: Double? = nil
    var timeZoneID: String = ""
    var arriveDate: Date = Date.distantPast   // first day here (startOfDay)
    var departDate: Date = Date.distantPast   // LAST day here, inclusive
    var externalID: String = ""       // the calendar event it came from

    init(id: UUID = UUID(), tripID: UUID, place: String, address: String = "",
         lat: Double? = nil, lng: Double? = nil, timeZoneID: String = "",
         arriveDate: Date, departDate: Date, externalID: String = "") {
        self.id = id
        self.tripID = tripID
        self.place = place
        self.address = address
        self.lat = lat
        self.lng = lng
        self.timeZoneID = timeZoneID
        self.arriveDate = arriveDate.startOfDay
        self.departDate = departDate.startOfDay
        self.externalID = externalID
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    nonisolated func covers(_ day: Date, calendar: Calendar = .current) -> Bool {
        let d = calendar.startOfDay(for: day)
        return d >= calendar.startOfDay(for: arriveDate) && d <= calendar.startOfDay(for: departDate)
    }
}

// MARK: - Making a sane itinerary out of messy calendar ranges

enum Itinerary {

    /// A stay reduced to the facts the resolver needs.
    nonisolated struct Span: Sendable, Equatable {
        var place: String
        var start: Date
        var end: Date          // inclusive
        var externalID: String = ""
        var address: String = ""
    }

    /// Calendars overlap, because people add a new leg without trimming the old
    /// one: "Bali 3–12 Sep" and "Travel to Singapore 11–14 Sep" both claim the
    /// 11th and 12th. A later start means you MOVED, so it truncates whatever
    /// came before. Returns non-overlapping stays in order; a stay squeezed out
    /// of existence entirely is dropped.
    nonisolated static func resolveOverlaps(_ spans: [Span],
                                            calendar: Calendar = .current) -> [Span] {
        let sorted = spans.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var out: [Span] = []
        for var span in sorted {
            if span.end < span.start { span.end = span.start }
            if var previous = out.last, previous.end >= span.start {
                guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: span.start) else { continue }
                let newEnd = calendar.startOfDay(for: dayBefore)
                if newEnd < previous.start {
                    out.removeLast()          // fully swallowed by the newer stay
                } else {
                    previous.end = newEnd
                    out[out.count - 1] = previous
                }
            }
            out.append(span)
        }
        return out
    }

    /// The days you MOVE: the first day of a stay that follows another. These
    /// are the only days of a trip where anything is time-critical, so they're
    /// the days that need a journey.
    nonisolated struct Transition: Sendable, Equatable {
        var day: Date
        var from: Span
        var to: Span
    }

    nonisolated static func transitions(_ resolved: [Span]) -> [Transition] {
        zip(resolved, resolved.dropFirst()).map { a, b in
            Transition(day: b.start, from: a, to: b)
        }
    }

    /// The trip's outer bounds.
    nonisolated static func bounds(_ spans: [Span]) -> (start: Date, end: Date)? {
        guard let first = spans.map(\.start).min(), let last = spans.map(\.end).max() else { return nil }
        return (first, last)
    }
}

// MARK: - Reading a clock in another zone

/// The whole of Jeeves runs on the device's zone; only travel crosses one. So
/// rather than make every model zone-aware, these two pure helpers convert at
/// the edges — reading a wall-clock into an instant on the way in, and
/// rendering an instant back into local time on the way out.
enum TravelClock {

    /// "19:40, as it reads in Singapore" → the actual instant. The user types a
    /// wall-clock; the picker hands it back in the DEVICE's zone; we re-read
    /// those same digits in the journey's zone. Without this, a flight entered
    /// from Bengaluru as "19:40 SGT" would be stored 2½ hours wrong.
    nonisolated static func instant(readingWallClock wall: Date, in zone: TimeZone,
                                    deviceZone: TimeZone = .current) -> Date {
        var device = Calendar(identifier: .gregorian)
        device.timeZone = deviceZone
        let c = device.dateComponents([.year, .month, .day, .hour, .minute], from: wall)
        var target = Calendar(identifier: .gregorian)
        target.timeZone = zone
        return target.date(from: c) ?? wall
    }

    /// The inverse — an instant shown back to the picker as the wall-clock it
    /// reads in `zone`, so editing round-trips without drifting.
    nonisolated static func wallClock(of instant: Date, in zone: TimeZone,
                                      deviceZone: TimeZone = .current) -> Date {
        var source = Calendar(identifier: .gregorian)
        source.timeZone = zone
        let c = source.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        var device = Calendar(identifier: .gregorian)
        device.timeZone = deviceZone
        return device.date(from: c) ?? instant
    }

    nonisolated static func hhmm(_ instant: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = zone
        return f.string(from: instant)
    }

    /// "IST", "SGT", "GMT+8" — what the user recognises.
    nonisolated static func label(_ zone: TimeZone, at instant: Date = Date()) -> String {
        zone.abbreviation(for: instant) ?? zone.identifier
    }

    /// "+2 h 30" — how far the destination's clock is from the origin's, which
    /// is the number that makes an arrival time make sense.
    nonisolated static func offsetLabel(from: TimeZone, to: TimeZone, at instant: Date) -> String? {
        let delta = to.secondsFromGMT(for: instant) - from.secondsFromGMT(for: instant)
        guard delta != 0 else { return nil }
        let sign = delta > 0 ? "+" : "\u{2212}"
        let mins = abs(delta) / 60
        return "\(sign)\(LeaveBy.hours(mins))"
    }

    /// True when the two instants fall on different calendar days in their own
    /// zones — an overnight flight, which is worth saying out loud.
    nonisolated static func crossesDay(departure: Date, departureZone: TimeZone,
                                       arrival: Date, arrivalZone: TimeZone) -> Bool {
        var d = Calendar(identifier: .gregorian); d.timeZone = departureZone
        var a = Calendar(identifier: .gregorian); a.timeZone = arrivalZone
        let dc = d.dateComponents([.year, .month, .day], from: departure)
        let ac = a.dateComponents([.year, .month, .day], from: arrival)
        return dc != ac
    }
}

// MARK: - The leave-by arithmetic (pure)

enum LeaveBy {

    /// One line of the backward chain, newest (latest) first.
    nonisolated struct Step: Equatable, Sendable {
        var time: Date
        var label: String
        var detail: String
        var isLeave: Bool = false
    }

    nonisolated struct Plan: Equatable, Sendable {
        var leaveAt: Date
        var steps: [Step]
        /// True when nothing measured the journey — say so rather than implying
        /// a precision that isn't there.
        var travelIsEstimated: Bool
    }

    /// Backward chain for a FLIGHT: departure → cut-off → security → drive →
    /// leave. `travelMinutes` is the door-to-terminal journey.
    nonisolated static func forFlight(departAt: Date, checkInMinutes: Int, securityMinutes: Int,
                                      travelMinutes: Int, bufferMinutes: Int,
                                      isEstimated: Bool = true, label: String = "") -> Plan {
        let cutoff   = departAt.addingTimeInterval(-Double(checkInMinutes) * 60)
        let terminal = cutoff.addingTimeInterval(-Double(securityMinutes) * 60)
        let latest   = terminal.addingTimeInterval(-Double(travelMinutes) * 60)
        let leave    = latest.addingTimeInterval(-Double(bufferMinutes) * 60)
        // Chronological — the order the morning actually happens, so the list
        // reads top-to-bottom as a checklist and the departure comes last.
        return Plan(leaveAt: leave, steps: [
            Step(time: leave, label: "LEAVE", detail: "\(bufferMinutes) min of your own buffer", isLeave: true),
            Step(time: terminal, label: "Be at the terminal", detail: "\(travelMinutes) min journey + \(securityMinutes) min security"),
            Step(time: cutoff, label: "Airline cut-off", detail: "\(hours(checkInMinutes)) before departure"),
            Step(time: departAt, label: label.isEmpty ? "Departure" : "\(label) departs", detail: ""),
        ], travelIsEstimated: isEstimated)
    }

    /// Backward chain for a DRIVE: hard arrival → contingency → driving → stops
    /// → leave.
    nonisolated static func forDrive(arriveBy: Date, travelMinutes: Int, stopMinutes: Int,
                                     bufferMinutes: Int, isEstimated: Bool = true) -> Plan {
        let planned = arriveBy.addingTimeInterval(-Double(bufferMinutes) * 60)
        let afterStops = planned.addingTimeInterval(-Double(travelMinutes) * 60)
        let leave = afterStops.addingTimeInterval(-Double(stopMinutes) * 60)
        // Chronological: leave → drive (with stops) → planned arrival → the
        // deadline, last.
        var steps: [Step] = [
            Step(time: leave, label: "LEAVE",
                 detail: stopMinutes > 0 ? "\(hours(travelMinutes)) driving + \(stopMinutes) min stops"
                                         : "\(hours(travelMinutes)) driving",
                 isLeave: true),
        ]
        steps.append(Step(time: planned, label: "Planned arrival", detail: "\(bufferMinutes) min contingency in hand"))
        steps.append(Step(time: arriveBy, label: "Must be there", detail: "your deadline"))
        return Plan(leaveAt: leave, steps: steps, travelIsEstimated: isEstimated)
    }

    /// The chain for a stored segment, or nil when it lacks the times it needs.
    nonisolated static func plan(for s: TravelSegment) -> Plan? {
        switch s.mode {
        case .flight, .train:
            guard s.departAt != .distantPast else { return nil }
            return forFlight(departAt: s.departAt, checkInMinutes: s.checkInMinutes,
                             securityMinutes: s.securityMinutes, travelMinutes: s.travelMinutes,
                             bufferMinutes: s.bufferMinutes, isEstimated: s.travelIsEstimated,
                             label: s.label)
        case .drive:
            guard let by = s.arriveBy else { return nil }
            return forDrive(arriveBy: by, travelMinutes: s.travelMinutes,
                            stopMinutes: s.stopMinutes, bufferMinutes: s.bufferMinutes,
                            isEstimated: s.travelIsEstimated)
        }
    }

    nonisolated static func hours(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
