//
//  TravelGuard.swift
//  Jeeves
//
//  One invariant, enforced in one place: A TRIP OWNS ITS DAYS. If a trip
//  covers a day, no stored plan may exist for it and no generator may create
//  one. Without this, plans generated before a trip existed linger underneath
//  travel mode (the plan eval scored them 1/10 — interview prep scheduled
//  while the user flies to Bali), their block notifications still fire, and
//  the overnight auto-planner happily refills the days as they approach.
//
//  Every generator — Plan-my-day, the chat's plan_day/replan_today, and
//  AutoPlanService's overnight loop — asks the same question here, so the
//  rule can't drift out of sync per surface.
//

import Foundation
import SwiftData

enum TravelGuard {

    /// The trip covering this day, if any.
    static func tripCovering(_ day: Date, context: ModelContext) -> Trip? {
        ((try? context.fetch(FetchDescriptor<Trip>())) ?? []).first { $0.covers(day) }
    }

    static func isTravelDay(_ day: Date, context: ModelContext) -> Bool {
        tripCovering(day, context: context) != nil
    }

    /// EVERY trip covering this day, oldest start first. A handover day —
    /// land from trip A in the morning, leave for trip B in the afternoon —
    /// is legitimately covered by two trips, and rendering only the first
    /// hid trip B's leave-by chain on its most critical day.
    static func tripsCovering(_ day: Date, context: ModelContext) -> [Trip] {
        ((try? context.fetch(FetchDescriptor<Trip>())) ?? [])
            .filter { $0.covers(day) }
            .sorted { ($0.startDate, $0.id.uuidString) < ($1.startDate, $1.id.uuidString) }
    }

    /// A calendar re-sync changed a lodging event's span: move the stay with
    /// it and grow the trip to cover the new dates, then sweep. Growth only —
    /// shrinking a trip stays a deliberate act in the trip editor. Returns
    /// true when anything moved. (The scenario eval scored this flow 3/10:
    /// the event updated in place but the trip never followed, leaving the
    /// newly covered days planned and nudging.)
    @discardableResult
    static func absorbStay(externalID: String, title: String = "", address: String = "",
                           newStart: Date, newEnd: Date,
                           context: ModelContext) async -> Bool {
        guard !externalID.isEmpty else { return false }
        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        // Legacy stays predate externalID stamping — the Singapore stay
        // ignored every re-sync because nothing could find it. Fall back to
        // matching by the event's title/venue against stays overlapping the
        // event's new range, and HEAL the row by stamping the id, so the next
        // re-sync matches first time.
        let matched = stays.first(where: { $0.externalID == externalID })
            ?? stays
                .filter { s in
                    s.externalID.isEmpty
                        && (s.place == title || (!address.isEmpty && s.address == address))
                        && s.departDate >= newStart.startOfDay && s.arriveDate <= newEnd.startOfDay
                }
                .sorted { ($0.arriveDate, $0.id.uuidString) < ($1.arriveDate, $1.id.uuidString) }
                .first
        guard let stay = matched else { return false }
        if stay.externalID.isEmpty { stay.externalID = externalID }
        var changed = false
        let start = newStart.startOfDay
        if stay.arriveDate != start { stay.arriveDate = start; changed = true }

        // A calendar event's last day cannot say whether it is a night there or
        // the morning you leave, so writing it straight into departDate put the
        // OLD meaning back — silently reverting acceptTravel's conversion and
        // undoing the migration, on every re-sync of an unchanged event.
        //
        // Same rule as acceptTravel: a following stay settles it, nothing else
        // can. When one exists, the end IS that stay's arrival; when none does,
        // the raw date stands and the doubt is recorded rather than resolved.
        let all = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        let follower = all
            .filter { $0.tripID == stay.tripID && $0.id != stay.id && $0.arriveDate > start }
            .min { $0.arriveDate < $1.arriveDate }
        let (end, unsettled): (Date, Bool) = follower.map { ($0.arriveDate.startOfDay, false) }
            ?? (newEnd.startOfDay, true)

        if stay.departDate != end { stay.departDate = end; changed = true }
        if stay.endIsUnsettled != unsettled { stay.endIsUnsettled = unsettled; changed = true }
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        if let trip = trips.first(where: { $0.id == stay.tripID }) {
            if start < trip.startDate { trip.startDate = start; changed = true }
            if end > trip.endDate { trip.endDate = end; changed = true }
            if changed {
                EventLog.log(.tripExtended,
                             "\(trip.title.isEmpty ? "Trip" : trip.title) followed a calendar re-sync",
                             subject: trip.id, context: context)
            }
        }
        guard changed else { return false }
        context.saveOrLog("TravelGuard.absorbStay")
        await sweep(context: context)
        return true
    }

    /// "12–18 Aug" for event-log detail lines.
    static func dayRange(_ trip: Trip) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "\(f.string(from: trip.startDate))–\(f.string(from: trip.endDate))"
    }

    /// The message every generator returns when refused, so chat and UI speak
    /// with one voice.
    static func refusalMessage(for day: Date, trip: Trip) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return "\(f.string(from: day)) is in travel mode (\(trip.title.isEmpty ? "trip" : trip.title)) — nothing to plan. Your journeys and leave-by times are on the planner."
    }

    /// Grows a journey's trip to cover the days the journey actually spans —
    /// leave-by day through arrival day — then sweeps. EVERY path that writes
    /// a journey's times must call this (editor Save, the card's Measure, chat
    /// add_journey); the eval found each surface that skipped it left a
    /// journey rendered on no day at all, because cards only show on
    /// trip-covered days. Returns true when the window moved.
    @discardableResult
    static func absorb(_ segment: TravelSegment, context: ModelContext) async -> Bool {
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        guard let trip = trips.first(where: { $0.id == segment.tripID }) else { return false }
        var changed = false
        let leaveDay = segment.day
        if leaveDay < trip.startDate { trip.startDate = leaveDay; changed = true }
        if leaveDay > trip.endDate { trip.endDate = leaveDay; changed = true }
        if let landing = segment.arrivalDay, landing > trip.endDate {
            trip.endDate = landing
            changed = true
        }
        guard changed else { return false }
        context.saveOrLog("TravelGuard.absorb")
        EventLog.log(.tripExtended,
                     "\(trip.title.isEmpty ? "Trip" : trip.title) grew to cover a journey",
                     subject: trip.id, context: context)
        await sweep(context: context)
        return true
    }

    /// Deletes stored plans (and cancels their block notifications) for every
    /// trip-covered day. Idempotent and cheap; runs at launch and whenever a
    /// trip is created or its dates grow.
    static func sweep(context: ModelContext) async {
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        guard !trips.isEmpty else { return }
        let states = (try? context.fetch(FetchDescriptor<DailyPlanState>())) ?? []
        var swept: [Date] = []
        for state in states where state.generatedPlanJSON != nil {
            if trips.contains(where: { $0.covers(state.date) }) {
                state.generatedPlanJSON = nil
                state.planConfirmed = false
                swept.append(state.date)
            }
        }
        guard !swept.isEmpty else { return }
        context.saveOrLog("TravelGuard.sweep")
        EventLog.log(.plansSwept, "\(swept.count) day-plan(s) deleted under trips", context: context)
        for day in swept {
            await NotificationService.clear(for: day)
        }
    }
}
