//
//  TicketImportPlan.swift
//  Jeeves
//
//  What importing a ticket WOULD do, computed before anything is written.
//
//  The screen that decides whether this feature is any good is the one that
//  handles a collision. Both easy behaviours are wrong: creating a second trip
//  leaves two overlapping records of one journey (the failure this app has hit
//  before), and silently overwriting the first destroys whatever was attached
//  to it with no receipt.
//
//  So the import is a two-step: build a PLAN describing every row that would
//  be created, updated or removed, show it, and only then apply. Nothing here
//  touches a ModelContext — the plan is pure and therefore testable against
//  the real ticket and a real prior trip.
//

import Foundation

// MARK: - The plan

struct PlannedStay: Equatable, Sendable {
    var place: String
    var timeZoneID: String
    var arriveDate: Date      // startOfDay, first day there
    var departDate: Date      // startOfDay, LAST day there, inclusive
}

struct PlannedJourney: Equatable, Sendable {
    var label: String            // "SQ 511"
    var fromPlace: String        // "BLR · Kempegowda International"
    var toPlace: String
    var departAt: Date
    var arriveAt: Date
    var fromTimeZoneID: String
    var toTimeZoneID: String
    var fromTerminal: String?
    var toTerminal: String?
    /// International check-in cut-off the ticket itself states.
    var checkInMinutes: Int
}

/// What the import would do to the store.
enum ImportAction: Equatable, Sendable {
    /// No trip covers these days.
    case createTrip
    /// A trip already overlaps; its window and stays would be brought into
    /// line with the ticket.
    case updateTrip(existingTitle: String, existingStart: Date, existingEnd: Date)
}

struct TicketImportPlan: Equatable, Sendable {
    var action: ImportAction
    var tripTitle: String
    var tripStart: Date          // startOfDay of the first departure, local
    var tripEnd: Date            // startOfDay of the last arrival, local
    var stays: [PlannedStay]
    var journeys: [PlannedJourney]
    /// Stays already in the store that this import makes redundant — same
    /// place, wholly inside one of the new stays. Offered for removal, never
    /// removed without a yes.
    var redundantStays: [RedundantStay] = []
    var notes: [String] = []

    struct RedundantStay: Equatable, Sendable {
        var place: String
        var arriveDate: Date
        var departDate: Date
        var reason: String
    }

    nonisolated var dayCount: Int {
        let days = Calendar.current.dateComponents([.day], from: tripStart, to: tripEnd).day ?? 0
        return max(1, days + 1)
    }
}

/// The minimum a caller must tell us about an existing trip. Kept as a plain
/// struct so this file never imports SwiftData.
struct ExistingTrip: Equatable, Sendable {
    var title: String
    var startDate: Date
    var endDate: Date
    var stays: [ExistingStay]

    struct ExistingStay: Equatable, Sendable {
        var place: String
        var arriveDate: Date
        var departDate: Date
    }
}

// MARK: - Building it

enum TicketImportPlanner {

    /// Builds the plan. `existing` is any trip whose window overlaps the
    /// ticket — the caller finds it; deciding what to do about it lives here.
    nonisolated static func plan(from itinerary: ResolvedItinerary,
                     existing: ExistingTrip? = nil,
                     calendar: Calendar = .current) -> TicketImportPlan? {
        guard let first = itinerary.legs.first,
              let last = itinerary.legs.last else { return nil }

        // A trip's days are reckoned where the traveller is, so the window
        // starts on the departure's LOCAL day and ends on the arrival's.
        let startZone = TimeZone(identifier: first.fromZoneID) ?? .current
        let endZone = TimeZone(identifier: last.toZoneID) ?? .current
        let tripStart = startOfDay(first.departUTC, in: startZone, calendar: calendar)
        let tripEnd = startOfDay(last.arriveUTC, in: endZone, calendar: calendar)

        let stays = plannedStays(from: itinerary, calendar: calendar)
        let journeys = itinerary.legs.map(plannedJourney)

        let title = tripTitle(for: stays, itinerary: itinerary)

        var notes: [String] = []
        var action: ImportAction = .createTrip
        var redundant: [TicketImportPlan.RedundantStay] = []

        if let existing {
            action = .updateTrip(existingTitle: existing.title,
                                 existingStart: existing.startDate,
                                 existingEnd: existing.endDate)
            notes.append(contentsOf: differences(existing: existing,
                                                 newStart: tripStart, newEnd: tripEnd,
                                                 newStays: stays, calendar: calendar))
            redundant = redundantStays(existing: existing, against: stays, calendar: calendar)
        }

        return TicketImportPlan(action: action, tripTitle: title,
                                tripStart: tripStart, tripEnd: tripEnd,
                                stays: stays, journeys: journeys,
                                redundantStays: redundant, notes: notes)
    }

    // MARK: Stays

    /// A stay per long gap. The gap between landing and the next departure is
    /// the time actually spent somewhere, so the stay's first day is the
    /// arrival's local day and its last day is the departure's — inclusive,
    /// matching TripStay's own convention.
    nonisolated static func plannedStays(from itinerary: ResolvedItinerary,
                             calendar: Calendar = .current) -> [PlannedStay] {
        var out: [PlannedStay] = []
        for (index, gap) in itinerary.layovers.enumerated() where gap.kind == .stay {
            let arrival = itinerary.legs[index]         // the leg that landed
            let departure = itinerary.legs[index + 1]   // the leg that leaves
            let zone = TimeZone(identifier: arrival.toZoneID) ?? .current
            out.append(PlannedStay(
                place: AirportDirectory.airport(gap.at)?.name.isEmpty == false
                    ? cityName(for: gap.at) : gap.at,
                timeZoneID: arrival.toZoneID,
                arriveDate: startOfDay(arrival.arriveUTC, in: zone, calendar: calendar),
                departDate: startOfDay(departure.departUTC, in: zone, calendar: calendar)))
        }
        return out
    }

    /// A stay is named for its place, not its airport building — "Bali", not
    /// "Ngurah Rai". Falls back to the code so a label is never empty.
    nonisolated static func cityName(for iata: String) -> String {
        switch iata.uppercased() {
        case "DPS": return "Bali"
        case "SIN": return "Singapore"
        case "BLR": return "Bengaluru"
        case "BKK", "DMK": return "Bangkok"
        case "CGK": return "Jakarta"
        case "KUL": return "Kuala Lumpur"
        case "PBH": return "Paro"
        case "CMB": return "Colombo"
        case "MLE": return "Maldives"
        case "KTM": return "Kathmandu"
        case "DXB": return "Dubai"
        case "LHR": return "London"
        case "JFK": return "New York"
        default:    return AirportDirectory.airport(iata)?.name ?? iata.uppercased()
        }
    }

    nonisolated static func plannedJourney(_ leg: ResolvedLeg) -> PlannedJourney {
        PlannedJourney(
            label: leg.leg.flightNumber,
            fromPlace: "\(leg.leg.from) · \(leg.fromName)",
            toPlace: "\(leg.leg.to) · \(leg.toName)",
            departAt: leg.departUTC,
            arriveAt: leg.arriveUTC,
            fromTimeZoneID: leg.fromZoneID,
            toTimeZoneID: leg.toZoneID,
            fromTerminal: leg.leg.fromTerminal,
            toTerminal: leg.leg.toTerminal,
            // The ticket's own words: international check-in opens 4h before.
            checkInMinutes: 240)
    }

    /// "Bali & Singapore" — named for where you actually stay, in order.
    nonisolated static func tripTitle(for stays: [PlannedStay], itinerary: ResolvedItinerary) -> String {
        let places = stays.map(\.place)
        switch places.count {
        case 0:  return itinerary.legs.last.map { cityName(for: $0.leg.to) } ?? "Trip"
        case 1:  return places[0]
        case 2:  return "\(places[0]) & \(places[1])"
        default: return places.dropLast().joined(separator: ", ") + " & " + places[places.count - 1]
        }
    }

    // MARK: Collision

    /// Plain-language differences between what's stored and what the ticket
    /// says. These are what the review sheet shows — a collision the user
    /// can't understand is a collision they'll resolve wrongly.
    nonisolated static func differences(existing: ExistingTrip,
                            newStart: Date, newEnd: Date,
                            newStays: [PlannedStay],
                            calendar: Calendar) -> [String] {
        var out: [String] = []
        let f = DateFormatter()
        f.dateFormat = "d MMM"

        if !calendar.isDate(existing.startDate, inSameDayAs: newStart) {
            out.append("Starts \(f.string(from: newStart)), not \(f.string(from: existing.startDate)).")
        }
        if !calendar.isDate(existing.endDate, inSameDayAs: newEnd) {
            out.append("Runs to \(f.string(from: newEnd)), not \(f.string(from: existing.endDate)).")
        }
        for stay in newStays {
            let match = existing.stays.first { $0.place.caseInsensitiveCompare(stay.place) == .orderedSame }
            if let match {
                if !calendar.isDate(match.arriveDate, inSameDayAs: stay.arriveDate) {
                    out.append("\(stay.place) starts \(f.string(from: stay.arriveDate)), not \(f.string(from: match.arriveDate)).")
                }
            } else {
                out.append("\(stay.place) isn't in the trip you have.")
            }
        }
        return out
    }

    /// Existing stays this import makes redundant: same place, and wholly
    /// inside one of the new stays. Exactly the shape of the leftover
    /// single-day duplicates the audit reports.
    ///
    /// Deliberately conservative — a stay that merely overlaps is NOT
    /// redundant, because it may be a real separate visit.
    nonisolated static func redundantStays(existing: ExistingTrip,
                               against newStays: [PlannedStay],
                               calendar: Calendar) -> [TicketImportPlan.RedundantStay] {
        var out: [TicketImportPlan.RedundantStay] = []
        for old in existing.stays {
            for new in newStays
            where old.place.caseInsensitiveCompare(new.place) == .orderedSame
                && old.arriveDate >= new.arriveDate
                && old.departDate <= new.departDate
                && !(calendar.isDate(old.arriveDate, inSameDayAs: new.arriveDate)
                     && calendar.isDate(old.departDate, inSameDayAs: new.departDate)) {
                let f = DateFormatter(); f.dateFormat = "d MMM"
                out.append(.init(place: old.place,
                                 arriveDate: old.arriveDate,
                                 departDate: old.departDate,
                                 reason: "inside \(new.place) \(f.string(from: new.arriveDate))–\(f.string(from: new.departDate))"))
                break
            }
        }
        return out
    }

    // MARK: Helpers

    nonisolated static func startOfDay(_ instant: Date, in zone: TimeZone, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.timeZone = zone
        return cal.startOfDay(for: instant)
    }
}
