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
