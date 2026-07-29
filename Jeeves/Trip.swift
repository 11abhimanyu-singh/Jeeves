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
    var departAt: Date = Date.distantPast
    /// Drives: the hard "must be there by". Flights: nil.
    var arriveBy: Date? = nil

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
         departAt: Date = .distantPast, arriveBy: Date? = nil,
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

    /// The day this segment belongs to — its departure for a flight, its
    /// arrival deadline for a drive.
    var day: Date { (mode == .drive ? (arriveBy ?? departAt) : departAt).startOfDay }
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
        return Plan(leaveAt: leave, steps: [
            Step(time: departAt, label: label.isEmpty ? "Departure" : "\(label) departs", detail: ""),
            Step(time: cutoff, label: "Airline cut-off", detail: "\(hours(checkInMinutes)) before"),
            Step(time: terminal, label: "Be at the terminal", detail: "\(securityMinutes) min immigration & security"),
            Step(time: latest, label: "Latest you could leave", detail: "\(travelMinutes) min journey"),
            Step(time: leave, label: "LEAVE", detail: "\(bufferMinutes) min of your own buffer", isLeave: true),
        ], travelIsEstimated: isEstimated)
    }

    /// Backward chain for a DRIVE: hard arrival → contingency → driving → stops
    /// → leave.
    nonisolated static func forDrive(arriveBy: Date, travelMinutes: Int, stopMinutes: Int,
                                     bufferMinutes: Int, isEstimated: Bool = true) -> Plan {
        let planned = arriveBy.addingTimeInterval(-Double(bufferMinutes) * 60)
        let afterStops = planned.addingTimeInterval(-Double(travelMinutes) * 60)
        let leave = afterStops.addingTimeInterval(-Double(stopMinutes) * 60)
        var steps: [Step] = [
            Step(time: arriveBy, label: "Must be there", detail: "your deadline"),
            Step(time: planned, label: "Planned arrival", detail: "\(bufferMinutes) min contingency"),
        ]
        if stopMinutes > 0 {
            steps.append(Step(time: afterStops, label: "Driving", detail: hours(travelMinutes)))
            steps.append(Step(time: leave, label: "LEAVE", detail: "\(stopMinutes) min of stops on route", isLeave: true))
        } else {
            steps.append(Step(time: leave, label: "LEAVE", detail: "\(hours(travelMinutes)) driving", isLeave: true))
        }
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
