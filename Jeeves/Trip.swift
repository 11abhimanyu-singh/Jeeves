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
    /// When the measurement was taken. A bare Bool made a traffic prediction
    /// pulled sixteen days out and a live reading taken ten minutes ago render
    /// identically, and the first of those is a guess about a Thursday evening
    /// nobody has driven yet. Optional because rows written before this existed
    /// genuinely don't know — and because CloudKit needs every stored property
    /// to be optional or defaulted.
    var measuredAt: Date? = nil
    /// True when nobody chose this mode — the calendar path picked it. Every
    /// stay-to-stay move was written as `.drive` because a lodge transfer
    /// dressed as a flight once demanded a 3 h airline cut-off for a two-hour
    /// road journey. That default is right for Kabini → Bandipur and wrong for
    /// Bali → Singapore, from inputs that look identical, so the assumption has
    /// to be visible rather than silent.
    var modeIsAssumed: Bool = false
    /// Why the assumed mode was refuted, in the user's terms. Empty when
    /// nothing has contradicted it.
    ///
    /// The road answer arrives once, in a background measurement, and is gone.
    /// Without somewhere to put the verdict the card could say "I've assumed
    /// you're driving" but never "…and there is no road route to Singapore",
    /// which is the half that tells you what to do about it.
    var modeRefutation: String = ""
    /// Boarded airside off the previous leg. There is no journey to it, so
    /// there is nothing to leave for — `LeaveBy.plan` returns nil rather than
    /// inventing a cut-off for an airport you never left.
    var isAirsideConnection: Bool = false

    init(id: UUID = UUID(), tripID: UUID, mode: TravelMode, label: String,
         fromPlace: String = "", toPlace: String = "",
         departAt: Date = .distantPast, arriveBy: Date? = nil, arriveAt: Date? = nil,
         fromTimeZoneID: String = "", toTimeZoneID: String = "",
         checkInMinutes: Int = defaultInternationalCheckInMinutes,
         securityMinutes: Int = 30, bufferMinutes: Int = 20,
         stopMinutes: Int = 0, travelMinutes: Int = 0, travelIsEstimated: Bool = true,
         measuredAt: Date? = nil, modeIsAssumed: Bool = false,
         modeRefutation: String = "",
         isAirsideConnection: Bool = false) {
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
        self.measuredAt = measuredAt
        self.modeIsAssumed = modeIsAssumed
        self.modeRefutation = modeRefutation
        self.isAirsideConnection = isAirsideConnection
    }

    /// Airline guidance for an international departure, and the value a
    /// hand-entered journey has always started from. Named so the ticket
    /// importer can share it rather than restate a different number.
    nonisolated static let defaultInternationalCheckInMinutes = 180

    /// How much a stored journey time is worth right now.
    ///
    /// Three states, not two. `travelIsEstimated == false` used to mean "Maps
    /// priced it" and nothing more, so a traffic PREDICTION for a departure two
    /// weeks away was indistinguishable from a reading taken minutes ago — and
    /// only one of those should let a leave-by notification fire unquestioned.
    nonisolated enum Freshness: Sendable, Equatable {
        case never                     // nobody has measured this
        case undated                   // measured, but nothing recorded when
        case predicted(daysAhead: Int) // measured for a departure still in the future
        case live(ageMinutes: Int)     // measured close to the journey itself
    }

    /// The ONE way a measured journey time is stored. Five call sites used to
    /// set `travelMinutes` and clear `travelIsEstimated` by hand, and adding a
    /// timestamp to four of them would have been worse than adding it to none.
    ///
    /// `settlesMode` defaults to true because a route that came back at all is
    /// normally proof the mode was right. The exception is a road answer so
    /// long that nobody would drive it: the minutes are real and worth keeping,
    /// but they are not evidence for `.drive`.
    func record(minutes: Int, now: Date = Date(), settlesMode: Bool = true) {
        travelMinutes = minutes
        travelIsEstimated = false
        measuredAt = now
        if settlesMode {
            modeIsAssumed = false
            modeRefutation = ""   // the road agreed; nothing left to explain
        }
    }

    /// The instant this journey actually happens. A drive has no departure —
    /// it carries an arrive-by — so `departAt` stays `.distantPast` on every
    /// one the app creates. Reading it directly made `.predicted` unreachable
    /// for precisely the segments the freshness distinction exists for, and the
    /// test that was supposed to prove otherwise used a flight-shaped fixture.
    /// Mirrors how `day` already resolves the same question.
    nonisolated var journeyInstant: Date? {
        switch mode {
        case .drive:            return arriveBy
        case .flight, .train:   return departAt == .distantPast ? nil : departAt
        }
    }

    /// `now` and the journey instant are passed in so this stays pure and testable.
    nonisolated func freshness(now: Date = Date()) -> Freshness {
        guard !travelIsEstimated else { return .never }
        // A row that says "measured" with no timestamp comes from a device that
        // predates `measuredAt` — this app mirrors through CloudKit, so an old
        // build on another phone keeps writing them. Rendering those as
        // "measured against live traffic" claims a freshness nobody recorded.
        guard let taken = measuredAt else { return .undated }
        let ageMinutes = max(0, Int(now.timeIntervalSince(taken) / 60))
        guard let anchor = journeyInstant else { return .live(ageMinutes: ageMinutes) }
        let untilDeparture = anchor.timeIntervalSince(taken)
        // A measurement taken more than a day before the journey is a forecast
        // of a road nobody has driven yet, however recently it was fetched.
        if untilDeparture > 24 * 3600 {
            // Rounded, not truncated. Truncation reported a measurement taken
            // 15.99 days out as "15 days ahead", which understates how much of
            // a forecast it is — and understating is the one direction this
            // number must never err in.
            return .predicted(daysAhead: Int((untilDeparture / 86_400).rounded()))
        }
        return .live(ageMinutes: ageMinutes)
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

    /// "UL 174" / "ul-174" / "UL174" all normalise to "UL174". A flight number
    /// identifies a leg on its own, which destination text does not: the same
    /// flight described once as "Colombo" and once as "Bandaranaike Airport"
    /// used to slip past dedup and land twice. Empty for anything that isn't
    /// shaped like a flight number (drives carry prose labels).
    nonisolated static func normalizedFlightNumber(_ label: String) -> String {
        let squashed = label.uppercased().filter { $0.isLetter || $0.isNumber }
        // A flight number is 1-3 letters then 1-4 digits, nothing else.
        let letters = squashed.prefix { $0.isLetter }
        let digits = squashed.dropFirst(letters.count)
        guard (1...3).contains(letters.count), (1...4).contains(digits.count),
              digits.allSatisfy({ $0.isNumber }) else { return "" }
        return String(squashed)
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
    // Hotel policy, in minutes past midnight on the stay's own clock. A stay
    // used to be whole days only, so a transition drive had nothing to aim at
    // and guessed noon — which is both before most check-ins and after most
    // checkouts. Defaults are the common Indian hotel windows.
    var checkinMinute: Int = StayWindow.defaultCheckin    // 14:00
    var checkoutMinute: Int = StayWindow.defaultCheckout  // 11:30
    /// Whether `departDate` is known to be the last night, or is still the
    /// calendar's unresolved guess.
    ///
    /// `Itinerary.Span` learned this distinction, but a Span is transient — it
    /// exists for the length of one `acceptTravel` call. Every stay it produced
    /// was saved here with the flag dropped, so the fix evaporated at the first
    /// save and a re-sync rebuilt the same ambiguity. A meaning that only holds
    /// in memory is not a meaning the store has.
    var endIsUnsettled: Bool = false

    init(id: UUID = UUID(), tripID: UUID, place: String, address: String = "",
         lat: Double? = nil, lng: Double? = nil, timeZoneID: String = "",
         arriveDate: Date, departDate: Date, externalID: String = "",
         checkinMinute: Int = StayWindow.defaultCheckin,
         checkoutMinute: Int = StayWindow.defaultCheckout,
         endIsUnsettled: Bool = false) {
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
        self.checkinMinute = checkinMinute
        self.checkoutMinute = checkoutMinute
        self.endIsUnsettled = endIsUnsettled
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    /// Nights slept here.
    ///
    /// `departDate` is the last day you are PRESENT — the day you leave — which
    /// is what `covers()` needs and what the ticket importer already writes
    /// (Singapore 11–14 Sep is three nights, because SQ 510 goes at 20:05 on
    /// the 14th). So the count is the plain difference, not the difference plus
    /// one: the day you leave is not a night.
    ///
    /// The calendar path used to write the last NIGHT here instead, which made
    /// the same field mean two different things depending on which importer
    /// filled it, and any count over a trip wrong for one of its stays.
    nonisolated func nights(calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: arriveDate),
                                           to: calendar.startOfDay(for: departDate)).day ?? 0
        return max(0, days)
    }

    /// What may be shown. One answer when the end is settled; two when it is
    /// not — and "3 or 4" is the honest rendering, never the mean and never the
    /// lower one because it reads more tidily.
    ///
    /// The doubt runs UPWARD: an unsettled `departDate` might be the day you
    /// leave (n nights) or a final night with departure the morning after
    /// (n + 1). An all-day block "20–23 Aug" is three nights or four, and
    /// nothing in a calendar can say which.
    nonisolated func nightsRange(calendar: Calendar = .current) -> ClosedRange<Int> {
        let n = nights(calendar: calendar)
        return endIsUnsettled ? n...(n + 1) : n...n
    }

    /// The nights count as a string, carrying its own uncertainty.
    nonisolated func nightsText(calendar: Calendar = .current) -> String {
        let r = nightsRange(calendar: calendar)
        let unit = r.upperBound == 1 ? "night" : "nights"
        return r.lowerBound == r.upperBound
            ? "\(r.lowerBound) \(unit)"
            : "\(r.lowerBound) or \(r.upperBound) \(unit)"
    }

    nonisolated func covers(_ day: Date, calendar: Calendar = .current) -> Bool {
        let d = calendar.startOfDay(for: day)
        return d >= calendar.startOfDay(for: arriveDate) && d <= calendar.startOfDay(for: departDate)
    }
}

// MARK: - Making a sane itinerary out of messy calendar ranges

enum Itinerary {

    /// A stay reduced to the facts the resolver needs.
    ///
    /// `end` is **the last night slept here**, inclusive. That is already what
    /// `resolveOverlaps` produces when a later stay truncates an earlier one —
    /// a stay that ends because you moved on the 20th slept its last night on
    /// the 19th. The trap is the stay nothing follows: its `end` arrives
    /// straight from the source, and an all-day block "20–23 Aug" cannot say
    /// whether the 23rd is a last night or the morning you leave. Both ends
    /// were being read as one thing, so any nights count over a trip was wrong
    /// for one of its stays. `endIsUnsettled` marks which is which.
    nonisolated struct Span: Sendable, Equatable {
        var place: String
        var start: Date
        var end: Date          // inclusive — the last night slept here
        var externalID: String = ""
        var address: String = ""
        /// True when `end` came from the source and nothing settled it. A
        /// nights count over this span is uncertain by exactly one, and must
        /// be rendered as a pair rather than a number.
        var endIsUnsettled: Bool = false
    }

    // Nights are counted on TripStay, not here. These two once existed on Span
    // as well, counting the OTHER way (end as last-night, +1) — two functions
    // of the same name disagreeing by one, which is precisely the confusion
    // this branch set out to remove. A Span is a transient input to the
    // resolver; only the stored stay has a nights count worth asking for.

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
                    // A stay you moved out of has a settled end: the next stay
                    // starting on the 20th proves the 19th was the last night.
                    previous.endIsUnsettled = false
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

/// Where a new journey's From/To prefill from. Pure and tested, because the
/// hotel-as-flight-destination bug shipped twice: first on the outbound leg
/// (Kathmandu — measured a 40 h road route), then mirrored on the return leg
/// (To = Home for a flight — measured a 46 h road route into the flight's
/// door-to-terminal slot). The rule, both directions: a flight's To is the
/// departure airport, which nothing stored can know — it stays EMPTY.
enum JourneyPrefill {
    nonisolated static func places(mode: TravelMode, isReturn: Bool, home: String,
                                   lastStay: String?, firstStay: String?,
                                   priorStay: String?) -> (from: String, to: String) {
        if isReturn {
            // Leaving the trip's last stay; a drive heads Home.
            return (lastStay ?? "", mode == .drive ? home : "")
        }
        // Outbound: leaving wherever you were last (a prior trip's stay that
        // ends as this one begins, else Home); a drive heads to the first stay.
        return (priorStay ?? home, mode == .drive ? (firstStay ?? "") : "")
    }
}

enum LeaveBy {

    /// A flight's door-to-terminal journey longer than this is a road trip
    /// wearing a boarding pass. Refused EVERYWHERE — measurement, the manual
    /// override, and chat's travel_minutes — because the scenario eval showed
    /// the guard leaking through the override and the chat parameter.
    nonisolated static let maxFlightJourneyMinutes = 360

    nonisolated static func plausibleFlightJourney(_ minutes: Int) -> Bool {
        minutes <= maxFlightJourneyMinutes
    }

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
        // Nothing to leave for. You are already airside, the gate is a walk
        // away, and a chain here would subtract a three-hour cut-off from a
        // flight you board without passing a check-in desk.
        guard !s.isAirsideConnection else { return nil }
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
