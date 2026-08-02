//
//  FlightWatchPolicy.swift
//  Jeeves
//
//  When to check a flight, and when to stop.
//
//  The rule: start twelve hours before departure, check about hourly, and stop
//  the moment the aircraft leaves. Before the window there is nothing to say —
//  a September flight in August cannot be usefully delayed — and after
//  departure nothing further can change.
//
//  A HONEST NOTE ABOUT "EVERY HOUR"
//
//  iOS does not let an app poll on a schedule. BGAppRefreshTask is granted
//  opportunistically: the system decides, based on charge, network, and how
//  often you open the app, and it may skip hours entirely or never run at all.
//  The same caveat is written on CommuteBackgroundRefresh for the same reason.
//
//  So this asks for hourly and treats every grant as a bonus. What makes the
//  feature honest rather than a promise it cannot keep is the other half: the
//  app also refreshes on foreground, and when neither has happened recently
//  the status line says so rather than showing a stale reading as current.
//  "Every hour" is the intent; `.stale` is the truth when iOS disagrees.
//

import Foundation

enum FlightWatchPolicy {

    /// How far ahead of departure watching begins.
    nonisolated static let windowHours = FlightWatch.windowHours   // 12

    /// The cadence asked of the system. Not a guarantee — see the note above.
    nonisolated static let pollMinutes = 60

    /// Near departure a delay matters more per minute, so ask more often. iOS
    /// still decides, but the request is shaped to where the value is.
    nonisolated static let finalApproachMinutes = 20
    nonisolated static let finalApproachStartsHoursBefore = 2

    /// Stop chasing a flight this long past its scheduled time even if the
    /// provider never reported a departure — the data is not coming.
    nonisolated static let abandonAfterHours = 6

    /// When watching opens for a given departure.
    nonisolated static func windowOpens(before scheduledDeparture: Date) -> Date {
        scheduledDeparture.addingTimeInterval(-Double(windowHours) * 3600)
    }

    /// Is this flight worth checking at all right now?
    ///
    /// `lastReport` is whatever is already known. A departed or cancelled
    /// flight is finished; so is one long past its time with nothing arriving.
    nonisolated static func shouldWatch(scheduledDeparture: Date,
                                        lastReport: FlightStatusReport?,
                                        now: Date = Date()) -> Bool {
        if let lastReport, lastReport.hasDeparted || lastReport.isCancelled { return false }
        if now < windowOpens(before: scheduledDeparture) { return false }
        let giveUp = scheduledDeparture.addingTimeInterval(Double(abandonAfterHours) * 3600)
        return now <= giveUp
    }

    /// When the next check is due. Nil once there is nothing left to check.
    ///
    /// Cadence tightens inside the final approach, and the first check is due
    /// immediately when the window opens rather than an hour into it.
    nonisolated static func nextCheck(scheduledDeparture: Date,
                                      lastChecked: Date?,
                                      lastReport: FlightStatusReport? = nil,
                                      now: Date = Date()) -> Date? {
        guard shouldWatch(scheduledDeparture: scheduledDeparture,
                          lastReport: lastReport, now: now) || now < windowOpens(before: scheduledDeparture)
        else { return nil }
        if let lastReport, lastReport.hasDeparted || lastReport.isCancelled { return nil }

        let opens = windowOpens(before: scheduledDeparture)
        guard let lastChecked else {
            // Never checked: due when the window opens, or now if it already has.
            return max(opens, now)
        }
        let interval = Double(cadenceMinutes(scheduledDeparture: scheduledDeparture,
                                             at: lastChecked)) * 60
        return max(lastChecked.addingTimeInterval(interval), opens)
    }

    /// Minutes between checks at a given moment.
    nonisolated static func cadenceMinutes(scheduledDeparture: Date, at moment: Date) -> Int {
        let toDeparture = scheduledDeparture.timeIntervalSince(moment) / 3600
        return toDeparture <= Double(finalApproachStartsHoursBefore)
            ? finalApproachMinutes : pollMinutes
    }

    /// Is a check due now?
    nonisolated static func isDue(scheduledDeparture: Date,
                                  lastChecked: Date?,
                                  lastReport: FlightStatusReport? = nil,
                                  now: Date = Date()) -> Bool {
        guard shouldWatch(scheduledDeparture: scheduledDeparture,
                          lastReport: lastReport, now: now) else { return false }
        guard let due = nextCheck(scheduledDeparture: scheduledDeparture,
                                  lastChecked: lastChecked,
                                  lastReport: lastReport, now: now) else { return false }
        return now >= due
    }

    /// Across a whole trip, the soonest moment any leg wants checking — what a
    /// single background task should be scheduled for.
    nonisolated static func earliestNextCheck(departures: [(scheduled: Date, lastChecked: Date?)],
                                              now: Date = Date()) -> Date? {
        departures.compactMap { nextCheck(scheduledDeparture: $0.scheduled,
                                          lastChecked: $0.lastChecked, now: now) }
            .filter { $0 >= now }
            .min()
    }
}

// MARK: - Remembering the last reading

/// Where the last successful reading per flight lives.
///
/// Small enough for UserDefaults and deliberately NOT in the SwiftData store:
/// a flight status is cached external data, not something the user authored,
/// and it should never sync to the watch or land in a backup as though it were
/// part of the trip.
enum FlightStatusStore {
    private static let key = "jeeves.flightStatus.cache"

    private struct Entry: Codable {
        var flightNumber: String
        var scheduledDeparture: Date
        var estimatedDeparture: Date
        var actualDeparture: Date?
        var isCancelled: Bool
        var departureTerminal: String?
        var arrivalTerminal: String?
        var observedAt: Date
        var lastCheckedAt: Date
    }

    /// One flight on one day. The date matters: the same number flies daily.
    nonisolated static func identity(flightNumber: String, scheduledDeparture: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return "\(flightNumber.replacingOccurrences(of: " ", with: ""))|\(f.string(from: scheduledDeparture))"
    }

    nonisolated static func save(_ report: FlightStatusReport, checkedAt: Date = Date()) {
        var all = load()
        all[identity(flightNumber: report.flightNumber,
                     scheduledDeparture: report.scheduledDeparture)] =
            Entry(flightNumber: report.flightNumber,
                  scheduledDeparture: report.scheduledDeparture,
                  estimatedDeparture: report.estimatedDeparture,
                  actualDeparture: report.actualDeparture,
                  isCancelled: report.isCancelled,
                  departureTerminal: report.departureTerminal,
                  arrivalTerminal: report.arrivalTerminal,
                  observedAt: report.observedAt,
                  lastCheckedAt: checkedAt)
        write(all)
    }

    nonisolated static func report(flightNumber: String,
                                   scheduledDeparture: Date) -> FlightStatusReport? {
        guard let e = load()[identity(flightNumber: flightNumber,
                                      scheduledDeparture: scheduledDeparture)] else { return nil }
        return FlightStatusReport(flightNumber: e.flightNumber,
                                  scheduledDeparture: e.scheduledDeparture,
                                  estimatedDeparture: e.estimatedDeparture,
                                  scheduledArrival: nil, estimatedArrival: nil,
                                  departureTerminal: e.departureTerminal,
                                  arrivalTerminal: e.arrivalTerminal,
                                  isCancelled: e.isCancelled,
                                  actualDeparture: e.actualDeparture,
                                  observedAt: e.observedAt)
    }

    nonisolated static func lastChecked(flightNumber: String,
                                        scheduledDeparture: Date) -> Date? {
        load()[identity(flightNumber: flightNumber,
                        scheduledDeparture: scheduledDeparture)]?.lastCheckedAt
    }

    /// Records that a check was ATTEMPTED, whether or not it succeeded — so a
    /// failing provider doesn't get hammered every wake-up.
    nonisolated static func markChecked(flightNumber: String,
                                        scheduledDeparture: Date, at: Date = Date()) {
        var all = load()
        let k = identity(flightNumber: flightNumber, scheduledDeparture: scheduledDeparture)
        if var existing = all[k] {
            existing.lastCheckedAt = at
            all[k] = existing
            write(all)
        }
    }

    /// Drops entries for flights long gone, so the cache can't grow forever.
    nonisolated static func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        write(load().filter { $0.value.scheduledDeparture > cutoff })
    }

    private nonisolated static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private nonisolated static func write(_ all: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
