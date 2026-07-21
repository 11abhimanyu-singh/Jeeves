//
//  CommuteRefresh.swift
//  Jeeves
//
//  A plan made this morning prices its commutes with this-morning's traffic.
//  This re-checks the traffic on a commute as its departure approaches (within
//  90 min) and, if the drive has changed enough to matter, rewrites the plan's
//  leave-by time, reschedules that reminder, and pings the user so they leave
//  at the right moment.
//
//  The decision logic is pure and unit-tested; execution (below) needs the
//  network and SwiftData. It runs when the app comes to the foreground and,
//  best-effort, from a background-refresh task shortly before departure.
//

import Foundation
import SwiftData

enum CommuteRefresh {
    /// Re-check a commute once it's due to depart within this many minutes.
    static let windowMinutes = 90
    /// Only rewrite the plan when the leave-by time moves at least this much —
    /// a one-minute traffic wobble isn't worth re-notifying over.
    static let materialChangeMinutes = 3

    /// A commute-to-anchor leg in the committed plan worth re-pricing: it sits
    /// immediately before a fixed event and has a resolvable origin/destination.
    struct DueLeg: Equatable {
        let commuteTitle: String
        let origin: String
        let destination: String
        let anchorStartMinute: Int    // the fixed event we must arrive for
        let currentDepartMinute: Int  // the commute block's current start
    }

    // MARK: Pure decision logic (unit-tested)

    /// Commute blocks in `plan` that lead into a fixed event, resolve to a real
    /// origin/destination, and depart within the window from `nowMinute`
    /// (and haven't already left). Pure.
    static func legsDue(plan: GeneratedPlan, events: [DailyEvent], locations: [SavedLocation], nowMinute: Int) -> [DueLeg] {
        var due: [DueLeg] = []
        let blocks = plan.blocks
        for (i, b) in blocks.enumerated() where b.kind.lowercased() == "commute" {
            guard let depart = b.startMinute,
                  depart >= nowMinute, depart <= nowMinute + windowMinutes,
                  i + 1 < blocks.count else { continue }
            let next = blocks[i + 1]
            guard next.kind.lowercased() == "event", let anchorStart = next.startMinute,
                  let event = matchingEvent(for: next.title, in: events),
                  !event.destinationAddress.isEmpty else { continue }
            let origin = locations.first { $0.kind == event.outboundStart }?.address
                ?? locations.first { $0.kind == .home }?.address ?? ""
            guard !origin.isEmpty else { continue }
            due.append(DueLeg(commuteTitle: b.title, origin: origin, destination: event.destinationAddress,
                              anchorStartMinute: anchorStart, currentDepartMinute: depart))
        }
        return due
    }

    /// The revised leave-by minute for a fresh traffic duration, and whether it
    /// moved materially from the plan's current departure. Pure.
    static func revisedDeparture(anchorStartMinute: Int, freshDurationMinutes: Int, currentDepartMinute: Int) -> (departMinute: Int, changed: Bool) {
        let depart = anchorStartMinute - freshDurationMinutes
        return (depart, abs(depart - currentDepartMinute) >= materialChangeMinutes)
    }

    /// Rewrites a commute block to leave at `newDepartMinute` and end at the
    /// anchor, trimming the immediately preceding block if an earlier departure
    /// would otherwise overlap it. Pure — everything else is untouched.
    static func applyDeparture(to plan: GeneratedPlan, commuteTitle: String, newDepartMinute: Int, anchorStartMinute: Int) -> GeneratedPlan {
        var blocks = plan.blocks
        guard let idx = blocks.firstIndex(where: { $0.title == commuteTitle && $0.kind.lowercased() == "commute" }) else { return plan }
        blocks[idx] = rebuilt(blocks[idx], startMinute: newDepartMinute, endMinute: anchorStartMinute)
        if idx > 0, let prevStart = blocks[idx - 1].startMinute, let prevEnd = blocks[idx - 1].endMinute,
           prevStart < newDepartMinute, prevEnd > newDepartMinute {
            blocks[idx - 1] = rebuilt(blocks[idx - 1], startMinute: prevStart, endMinute: newDepartMinute)
        }
        return GeneratedPlan(blocks: blocks, dropped: plan.dropped, shrunk: plan.shrunk,
                             summary: plan.summary, boundaryTime: plan.boundaryTime)
    }

    /// The soonest future event-commute departure in `plan` after `nowMinute` —
    /// used to schedule the next background refresh ~90 min ahead. Pure.
    static func nextDepartureMinute(plan: GeneratedPlan, events: [DailyEvent], locations: [SavedLocation], nowMinute: Int) -> Int? {
        let blocks = plan.blocks
        var soonest: Int?
        for (i, b) in blocks.enumerated() where b.kind.lowercased() == "commute" {
            guard let depart = b.startMinute, depart >= nowMinute, i + 1 < blocks.count else { continue }
            let next = blocks[i + 1]
            guard next.kind.lowercased() == "event",
                  let event = matchingEvent(for: next.title, in: events), !event.destinationAddress.isEmpty else { continue }
            soonest = min(soonest ?? depart, depart)
        }
        return soonest
    }

    private static func matchingEvent(for blockTitle: String, in events: [DailyEvent]) -> DailyEvent? {
        events.first { blockTitle.localizedCaseInsensitiveContains($0.title) || $0.title.localizedCaseInsensitiveContains(blockTitle) }
    }

    private static func rebuilt(_ b: GeneratedBlock, startMinute: Int, endMinute: Int) -> GeneratedBlock {
        GeneratedBlock(title: b.title, startTime: hhmm(startMinute), endTime: hhmm(endMinute),
                       note: b.note, isAnchor: b.isAnchor, kind: b.kind)
    }

    private static func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", (m / 60) % 24, m % 60) }

    // MARK: Execution (network + SwiftData)

    /// Re-prices today's imminent commute legs and, for any that changed
    /// materially, rewrites the stored plan, reschedules its reminders, and
    /// notifies the user. Safe to call repeatedly (foreground + background).
    @MainActor
    static func run(context: ModelContext, now: Date = Date()) async {
        let today = now.startOfDay
        guard let state = try? context.fetch(FetchDescriptor<DailyPlanState>(predicate: #Predicate { $0.date == today })).first,
              let plan = state.plan else { return }
        let events = (try? context.fetch(FetchDescriptor<DailyEvent>(predicate: #Predicate { $0.date == today }))) ?? []
        let locations = (try? context.fetch(FetchDescriptor<SavedLocation>())) ?? []

        let cal = Calendar.current
        let nowMinute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let due = legsDue(plan: plan, events: events, locations: locations, nowMinute: nowMinute)
        guard !due.isEmpty else { return }

        var working = plan
        var changed = false
        for leg in due {
            let departDate = cal.date(bySettingHour: leg.currentDepartMinute / 60, minute: leg.currentDepartMinute % 60, second: 0, of: today) ?? now
            guard let fresh = await GoogleMapsService.commuteMinutes(from: leg.origin, to: leg.destination, departure: departDate) else { continue }
            let revised = revisedDeparture(anchorStartMinute: leg.anchorStartMinute, freshDurationMinutes: fresh, currentDepartMinute: leg.currentDepartMinute)
            guard revised.changed else { continue }
            working = applyDeparture(to: working, commuteTitle: leg.commuteTitle, newDepartMinute: revised.departMinute, anchorStartMinute: leg.anchorStartMinute)
            changed = true
            await NotificationService.notifyCommuteUpdate(commuteTitle: leg.commuteTitle,
                                                          newDepartMinute: revised.departMinute,
                                                          earlierByMinutes: leg.currentDepartMinute - revised.departMinute)
        }
        guard changed else { return }
        state.storePlan(working, isOffline: state.generatedPlanIsOffline)
        try? context.save()
        await NotificationService.reschedule(plan: working, on: today)
    }
}
