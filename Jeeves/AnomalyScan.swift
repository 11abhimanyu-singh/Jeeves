//
//  AnomalyScan.swift
//  Jeeves
//
//  Behavioral + structural anomaly detection, surfaced — never silently
//  healed. The user designs fixes and UX from what this reports (a "close
//  the Run" nudge is only designable once "started at 23:01, never ended"
//  is visible), so this SCANS and NARRATES; it does not repair.
//
//  Structural rules read final states across ALL history, no date limits.
//  Behavioral rules read the AppEvent stream (which exists from the day the
//  event log shipped).
//
//  The digest mirrors to iCloud Drive beside the plan diagnostics:
//    .../iCloud~abhimanyusingh~me~Jeeves/Documents/jeeves-anomalies.json
//  so the Mac-side daily digest reads it with no cable.
//

import Foundation
import SwiftData

struct Anomaly: Codable, Sendable {
    var severity: String     // "high" | "medium" | "low"
    var day: String          // yyyy-MM-dd the anomaly belongs to
    var rule: String         // kebab-case rule id
    var title: String        // one-line headline
    var detail: String       // the narrative, with times
}

enum AnomalyScan {

    /// Every anomaly in the store — structural rules over all history,
    /// behavioral rules over the whole event stream.
    static func scan(context: ModelContext, now: Date = Date()) -> [Anomaly] {
        var out: [Anomaly] = []
        let cal = Calendar.current
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"

        let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        let events = ((try? context.fetch(FetchDescriptor<AppEvent>())) ?? [])
            .sorted { $0.date < $1.date }
        let checkIns = (try? context.fetch(FetchDescriptor<CheckIn>())) ?? []

        // ---- Structural: final states that shouldn't exist (all history) ----
        for w in workouts where w.state == .live && now.timeIntervalSince(w.date) > 12 * 3600 {
            out.append(Anomaly(
                severity: "high", day: dayFmt.string(from: w.date), rule: "stale-live-workout",
                title: "\(w.title) still 'live' since \(hm.string(from: w.date))",
                detail: "Started \(dayFmt.string(from: w.date)) \(hm.string(from: w.date)) from the \(w.source.rawValue), never ended — no watch summary ever arrived (duration 0, avg BPM 0). Either the session was abandoned on the watch or the end-of-workout handoff was lost."))
        }
        for w in workouts where w.source == .watch && w.state != .live
            && w.durationMin == 0 && !w.receivedWatchSummary {
            out.append(Anomaly(
                severity: "medium", day: dayFmt.string(from: w.date), rule: "shell-workout",
                title: "\(w.title) is an empty shell",
                detail: "A watch workout with no duration, no heart rate, and no summary — a start that produced nothing."))
        }
        // Check-in claims a workout on a day with no workout rows at all.
        for c in checkIns where c.workedOut {
            let d = cal.startOfDay(for: c.date)
            if !workouts.contains(where: { cal.isDate($0.date, inSameDayAs: d) }) {
                out.append(Anomaly(
                    severity: "low", day: dayFmt.string(from: c.date), rule: "checkin-without-workout",
                    title: "Check-in says workout, store has none",
                    detail: "The \(dayFmt.string(from: c.date)) check-in records a workout but no Workout row exists that day — logged by hand before the workout screens, or a lost record."))
            }
        }

        // ---- Behavioral: sequences in the event stream ----
        let starts = events.filter { $0.kind == .workoutStarted }
        let startsByDay = Dictionary(grouping: starts) { cal.startOfDay(for: $0.date) }
        for (d, dayStarts) in startsByDay where dayStarts.count > 2 {
            let times = dayStarts.map { hm.string(from: $0.date) }.joined(separator: ", ")
            out.append(Anomaly(
                severity: "medium", day: dayFmt.string(from: d), rule: "many-workout-starts",
                title: "Workout started \(dayStarts.count) times",
                detail: "Sessions began at \(times). One start is normal, two can be a pause-and-resume — \(dayStarts.count) usually means fumbled starts on the watch or a handoff loop."))
        }
        for s in starts {
            let sameDay = { (e: AppEvent) in cal.isDate(e.date, inSameDayAs: s.date) }
            let closed = events.contains {
                ($0.kind == .watchSummaryArrived || $0.kind == .watchSummaryCreated)
                    && sameDay($0) && $0.date >= s.date
            }
            if !closed, now.timeIntervalSince(s.date) > 12 * 3600 {
                out.append(Anomaly(
                    severity: "high", day: dayFmt.string(from: s.date), rule: "start-without-end",
                    title: "\(s.detail) started \(hm.string(from: s.date)), never ended",
                    detail: "No end-of-workout summary followed this start for the rest of the day. The watch either abandoned the session or the summary never reached the phone."))
            }
        }
        for e in events where e.kind == .watchSummaryCreated {
            out.append(Anomaly(
                severity: "low", day: dayFmt.string(from: e.date), rule: "summary-without-start",
                title: "Watch summary arrived with nothing to match",
                detail: "\(e.detail) — the end-of-workout summary landed but no live card existed, so a new row was created. The start heads-up was missed (phone unreachable at start?)."))
        }

        return out.sorted { ($0.day, $0.severity) > ($1.day, $1.severity) }
    }

    struct Digest: Codable, Sendable {
        var exportedAt: Date
        var count: Int
        var anomalies: [Anomaly]
        var eventCount: Int
    }

    /// Scan and mirror to iCloud Drive for the Mac-side daily digest.
    static func writeDigest(context: ModelContext, now: Date = Date()) {
        let anomalies = scan(context: context, now: now)
        let eventCount = (try? context.fetchCount(FetchDescriptor<AppEvent>())) ?? 0
        let digest = Digest(exportedAt: now, count: anomalies.count,
                            anomalies: anomalies, eventCount: eventCount)
        Task.detached(priority: .utility) {
            guard let docs = DiagnosticsSync.documentsURL() else { return }
            guard let data = try? DiagnosticsSync.encoder.encode(digest) else { return }
            let url = docs.appendingPathComponent("jeeves-anomalies.json")
            var err: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { target in
                try? data.write(to: target, options: .atomic)
            }
        }
    }
}
