//
//  TravelRepair.swift
//  Jeeves
//
//  Repairs for the travel store, split by blast radius — a hard lesson from
//  review: the first draft auto-merged and auto-deleted at launch, which on a
//  CloudKit store is destruction waiting to happen (a launch mid-sync sees
//  half-imported data and "repairs" it away, and the deletes propagate to
//  every device).
//
//  LAUNCH (automatic, every start) runs only provably-safe operations:
//  content-keyed fixes that converge to the same result on any device at any
//  sync state, and window GROWTH (never deletion, never shrink).
//
//  CLEANUP (user-invoked, via the clean_travel_data chat tool) does the
//  destructive tidying — merging duplicate trips, collapsing cloned stays,
//  deleting orphans — deliberately, when the user asks, with a receipt of
//  what changed.
//

import Foundation
import SwiftData

enum TravelRepair {

    // MARK: Launch — safe, automatic

    /// Content-keyed fixes that cannot destroy legitimate data:
    /// - phantom arrivals (arriveAt at or before departure was never real)
    /// - self-transitions (a journey from a place to itself is junk by
    ///   definition, whatever the sync state)
    static func repairSafe(context: ModelContext) {
        var changed = false
        let segments = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
        for s in segments {
            if let a = s.arriveAt, s.departAt != .distantPast, a <= s.departAt {
                s.arriveAt = nil
                changed = true
            }
        }
        for s in segments where !s.fromPlace.isEmpty && s.fromPlace == s.toPlace {
            TravelNotifier.cancel(segment: s)
            context.delete(s)
            changed = true
        }
        if changed { context.saveOrLog("TravelRepair.repairSafe") }
    }

    /// A trip covers its stays and its journeys — grow every trip's window to
    /// hold them, then sweep the newly covered days. Never shrinks, and only
    /// trusts anchors that are real: a segment with no computable leave-by
    /// (timeless rows exist and the UI renders them) or with an implausible
    /// flight journey (a legacy road-route measurement in the door-to-terminal
    /// slot) must not move a window — the first draft let a distantPast
    /// anchor drag a trip's start to year 1 and sweep all plan history.
    static func repairWindows(context: ModelContext) async {
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        guard !trips.isEmpty else { return }
        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        let segments = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
        var changed = false
        for trip in trips {
            var start = trip.startDate
            var end = trip.endDate
            for stay in stays where stay.tripID == trip.id {
                if stay.arriveDate > Date.distantPast { start = min(start, stay.arriveDate) }
                if stay.departDate > Date.distantPast { end = max(end, stay.departDate) }
            }
            for s in segments where s.tripID == trip.id {
                guard LeaveBy.plan(for: s) != nil else { continue }
                guard s.mode == .drive || s.travelMinutes <= 360 else { continue }
                start = min(start, s.day)
                if let landing = s.arrivalDay { end = max(end, landing) }
            }
            if start != trip.startDate || end != trip.endDate {
                trip.startDate = start
                trip.endDate = end
                changed = true
            }
        }
        guard changed else { return }
        context.saveOrLog("TravelRepair.repairWindows")
        await TravelGuard.sweep(context: context)
    }

    // MARK: Cleanup — destructive, user-invoked only

    struct CleanupSummary {
        var tripsMerged = 0
        var staysCollapsed = 0
        var orphansRemoved = 0
        var isEmpty: Bool { tripsMerged == 0 && staysCollapsed == 0 && orphansRemoved == 0 }
    }

    /// Destructive tidying, run only when the user asks. Rules hardened by
    /// review:
    /// - Trips merge only on STRICT INTERIOR overlap (sharing more than a
    ///   boundary day) — a trip ending the 11th and one starting the 11th is
    ///   the normal fly-out-on-the-last-day pattern, never merged.
    /// - Keeper selection is deterministic on stable data (startDate, endDate,
    ///   id string), so two devices running this pick the SAME keeper.
    /// - Twin rows sharing one UUID (CloudKit can mint them) are skipped —
    ///   there is no stable way to pick a winner, so they are left for the
    ///   audit to report.
    /// - Stays collapse only when their date ranges actually overlap; a
    ///   return to the same hotel later in the trip stays separate.
    static func cleanupLegacy(context: ModelContext) -> CleanupSummary {
        var summary = CleanupSummary()

        // 1. Merge strictly-overlapping trips into a deterministic keeper.
        var trips = ((try? context.fetch(FetchDescriptor<Trip>())) ?? [])
            .sorted {
                ($0.startDate, $0.endDate, $0.id.uuidString) < ($1.startDate, $1.endDate, $1.id.uuidString)
            }
        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        let segments = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
        var absorbedRows = Set<ObjectIdentifier>()
        for i in trips.indices {
            let a = trips[i]
            guard !absorbedRows.contains(ObjectIdentifier(a)) else { continue }
            for j in trips.indices where j > i {
                let b = trips[j]
                guard !absorbedRows.contains(ObjectIdentifier(b)), b.id != a.id else { continue }
                // Interior overlap always merges. Boundary-touch merges ONLY
                // for identically-titled trips: "Bali" ending the 11th and
                // "Bali" starting the 11th are clones from the duplicate-sync
                // era, not a handover — a real handover changes destination.
                let interior = a.endDate > b.startDate && b.endDate > a.startDate
                let sameTitleTouch = a.endDate >= b.startDate && b.endDate >= a.startDate
                    && !a.title.isEmpty
                    && a.title.compare(b.title, options: .caseInsensitive) == .orderedSame
                guard interior || sameTitleTouch else { continue }
                a.startDate = min(a.startDate, b.startDate)
                a.endDate = max(a.endDate, b.endDate)
                for stay in stays where stay.tripID == b.id { stay.tripID = a.id }
                for s in segments where s.tripID == b.id { s.tripID = a.id }
                absorbedRows.insert(ObjectIdentifier(b))
                context.delete(b)
                summary.tripsMerged += 1
            }
        }
        trips = trips.filter { !absorbedRows.contains(ObjectIdentifier($0)) }

        // 2. Collapse same-trip same-place stays whose dates OVERLAP, cluster
        //    by cluster; disjoint returns to the same hotel survive.
        let liveStays = stays.filter { stay in trips.contains { $0.id == stay.tripID } }
        let grouped = Dictionary(grouping: liveStays) { "\($0.tripID)|\($0.place)|\($0.address)" }
        var deletedStays = Set<ObjectIdentifier>()
        for (_, rows) in grouped where rows.count > 1 {
            let sorted = rows.sorted {
                ($0.arriveDate, $0.departDate, $0.id.uuidString) < ($1.arriveDate, $1.departDate, $1.id.uuidString)
            }
            var cluster: [TripStay] = []
            // The cluster's reach is its MAX depart, not the last row's — a
            // wide 3–11 stay followed by 4–4 must still absorb 5–5 and 7–7.
            // (Comparing against the last row let two clones survive and the
            // receipt say "collapsed 1" when the truth was 3.)
            var clusterEnd = Date.distantPast
            func collapse() {
                guard cluster.count > 1, let keeper = cluster.first else { return }
                keeper.arriveDate = cluster.map(\.arriveDate).min() ?? keeper.arriveDate
                keeper.departDate = cluster.map(\.departDate).max() ?? keeper.departDate
                for extra in cluster.dropFirst() {
                    deletedStays.insert(ObjectIdentifier(extra))
                    context.delete(extra)
                    summary.staysCollapsed += 1
                }
            }
            for stay in sorted {
                if !cluster.isEmpty, stay.arriveDate <= clusterEnd {
                    cluster.append(stay)
                    clusterEnd = max(clusterEnd, stay.departDate)
                } else {
                    collapse()
                    cluster = [stay]
                    clusterEnd = stay.departDate
                }
            }
            collapse()
        }

        // 2b. Clone journeys: iterating in chat used to mint a new segment
        //    per correction turn (four outbound drives to one waterfall).
        //    Same trip + mode + label + anchor day is the same leg — keep the
        //    best-informed one (measured beats unmeasured, then the latest
        //    time, then a stable id tiebreak) and cancel the losers' nudges.
        var deletedSegs = Set<ObjectIdentifier>()
        let liveSegs = segments.filter { s in trips.contains { $0.id == s.tripID } }
        let segGroups = Dictionary(grouping: liveSegs) { (s: TravelSegment) -> String in
            let anchor = s.mode == .drive ? (s.arriveBy ?? .distantPast) : s.departAt
            let day = Calendar.current.startOfDay(for: anchor)
            return "\(s.tripID)|\(s.modeRaw)|\(s.label.lowercased())|\(day.timeIntervalSinceReferenceDate)"
        }
        for (_, rows) in segGroups where rows.count > 1 {
            let ranked = rows.sorted {
                let a = ($0.travelMinutes > 0 ? 1 : 0, $0.arriveBy ?? $0.departAt, $0.id.uuidString)
                let b = ($1.travelMinutes > 0 ? 1 : 0, $1.arriveBy ?? $1.departAt, $1.id.uuidString)
                return a > b
            }
            for extra in ranked.dropFirst() {
                TravelNotifier.cancel(segment: extra)
                deletedSegs.insert(ObjectIdentifier(extra))
                context.delete(extra)
                summary.orphansRemoved += 1
            }
        }

        // 3. Rows whose trip is missing. Deliberate invocation means the user
        //    is looking at a synced store, not a mid-import launch.
        let tripIDs = Set(trips.map(\.id))
        for stay in stays
        where !tripIDs.contains(stay.tripID) && !deletedStays.contains(ObjectIdentifier(stay)) {
            context.delete(stay)
            summary.orphansRemoved += 1
        }
        for s in segments
        where !tripIDs.contains(s.tripID) && !deletedSegs.contains(ObjectIdentifier(s)) {
            TravelNotifier.cancel(segment: s)
            context.delete(s)
            summary.orphansRemoved += 1
        }

        if !summary.isEmpty { context.saveOrLog("TravelRepair.cleanupLegacy") }
        return summary
    }
}
