//
//  PlanCoordinator.swift
//  Jeeves
//
//  One place that turns a day's inputs (gym, events, locations, prep history)
//  into a plan — via Claude (PlanGenerationService) with a deterministic
//  offline fallback (DayPlanner). Both the Jeeves chat and the Day Planner tab
//  call this, so "Plan my day" behaves identically wherever it's triggered and
//  the result can be persisted to DailyPlanState.
//

import Foundation
import SwiftData

enum PlanCoordinator {
    struct Inputs {
        var userMessage: String = ""
        var hasGym: Bool
        var gymMinute: Int?
        var events: [DailyEvent]
        var locations: [SavedLocation]
        var prepSessions: [PrepSession]
        var routine: [BaselineActivity] = Baseline.activities  // the user's editable routine
        /// The gym's parts as configured — mobility/weightlifting/cardio are
        /// switchable and independently timed now, not three frozen numbers.
        var gymSession: [(name: String, minutes: Int)] = Baseline.gymParts
        var adherenceNote: String? = nil // recent done/skip history, so the plan adapts to what sticks
        var replanFromMinute: Int? = nil // mid-day re-plan: schedule only from here forward
        var alreadyDoneNote: String? = nil // titles done earlier today, so the re-plan doesn't re-add them
        var lockedBlocks: [GeneratedBlock] = [] // already-elapsed blocks to preserve verbatim across a re-plan
        var planDate: Date = Date()     // the day being planned — commute legs use its scheduled departure times for predictive traffic
        var referenceNow: Date? = nil   // pinned "now" for evals; nil = real clock

        // MARK: what a mid-day plan needs to work the elapsed day out for itself
        //
        // Callers used to compute this and hand over the ANSWERS
        // (replanFromMinute / lockedBlocks). Three of the five forgot, so a plan
        // asked for at 12:45 came back laid out from 07:00. They now hand over
        // the INPUTS and `resolved` does the arithmetic once.

        /// Today's committed plan, when there is one. Its elapsed blocks are
        /// what a re-plan preserves.
        var existingPlan: GeneratedPlan? = nil
        /// Blocks that ELAPSED but did not HAPPEN — named by the user, excluded
        /// from the preserved set so a re-plan can offer them again.
        var missedBlocks: [String] = []
        /// The user's stated ETA ("20 more minutes"), when they gave one. The
        /// remainder starts here rather than at the clock.
        var resumeAtMinute: Int? = nil
        /// This day was deliberately emptied. Distinct from an empty `routine`,
        /// which both planners would otherwise treat as "nothing configured"
        /// and helpfully fill.
        var blankDay: Bool = false
    }

    struct Result {
        let plan: GeneratedPlan
        let isOffline: Bool
        let error: String?
        var retryCount: Int = 0   // 1 when a repair round-trip was made
        var commuteMs: Int = 0    // time spent fetching commute times (Maps)
        var claudeMs: Int = 0     // time spent in the Claude call(s)
        /// Where this plan actually began, when it began mid-day. Reported so
        /// the UI describes what happened instead of predicting it.
        var resumedFromMinute: Int? = nil
        var keptBlocks: Int = 0
    }

    // MARK: Where the plan starts

    /// What a plan for a day already under way must begin from, and keep.
    struct Resumption: Equatable {
        /// The first minute the new plan may schedule.
        var fromMinute: Int
        /// Blocks that already elapsed and are preserved verbatim.
        var locked: [GeneratedBlock]
        /// Their titles, for the prompt — so the remainder doesn't re-offer them.
        var alreadyDoneNote: String?
    }

    /// Whether this is a whole day or the rest of one, worked out from the
    /// clock rather than from whether the caller remembered to say so.
    ///
    /// A plan asked for at 12:45 that opens with a 07:00 block is not a plan,
    /// it is a transcript. Returns nil when the day genuinely hasn't started
    /// (planning tomorrow, or planning today before the day-start minute),
    /// which is the only case where a full day is the right answer.
    ///
    /// Pure — the clock arrives as a parameter, so this is testable at any hour.
    static func resumption(planDate: Date, existingPlan: GeneratedPlan?,
                           hasGym: Bool, gymMinute: Int?, events: [DailyEvent],
                           missedBlocks: [String] = [], resumeAtMinute: Int? = nil,
                           now: Date = Date()) -> Resumption? {
        let cal = Calendar.current
        guard cal.isDate(planDate, inSameDayAs: now) else { return nil }
        let nowMinute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        // Never behind the clock: a stated ETA can push the start later, never
        // earlier. "I'll be back in 20 minutes" moves the day; "start at 9"
        // said at 11 does not un-spend the morning.
        let from = max(resumeAtMinute ?? nowMinute, nowMinute)
        guard from > DayPlanner.dayStartMinute else { return nil }

        var locked: [GeneratedBlock] = []
        if let existingPlan {
            // Anchors from the NEW inputs, not the old plan: if the gym just
            // moved to the evening, this morning's commute to it is no longer
            // a journey the day makes, and must not be preserved as done.
            let anchors = arrivalAnchors(
                gymMinute: hasGym ? gymMinute : nil,
                eventStarts: events.filter { !$0.isAllDay }.map(\.startMinute))
            locked = lockedBlocks(existingPlan, endedBy: nowMinute, stillArrivingAt: anchors)
            // ELAPSED IS NOT DONE. A block the user says they missed is dropped
            // from the preserved set so the remainder can offer it again.
            if !missedBlocks.isEmpty {
                locked = locked.filter { block in
                    !missedBlocks.contains { JeevesChatService.strictMatch(block.title, query: $0) }
                }
            }
        }
        let doneNote = locked.map(\.title).joined(separator: ", ")
        return Resumption(fromMinute: from, locked: locked,
                          alreadyDoneNote: doneNote.isEmpty ? nil : doneNote)
    }

    /// Inputs with the mid-day arithmetic filled in. An explicit
    /// `replanFromMinute` still wins — evals and tests pin the clock that way.
    static func resolved(_ i: Inputs) -> Inputs {
        // A cleared day is cleared all the way. Preserving the elapsed morning
        // is exactly right when re-planning around a delay, and exactly wrong
        // here: "cancel everything today and keep the day free" left fourteen
        // blocks on screen and looked like the button had done nothing.
        guard !i.blankDay else { return i }
        guard i.replanFromMinute == nil else { return i }
        guard let r = resumption(planDate: i.planDate, existingPlan: i.existingPlan,
                                 hasGym: i.hasGym, gymMinute: i.gymMinute, events: i.events,
                                 missedBlocks: i.missedBlocks, resumeAtMinute: i.resumeAtMinute,
                                 now: i.referenceNow ?? Date())
        else { return i }
        var out = i
        out.replanFromMinute = r.fromMinute
        out.lockedBlocks = r.locked
        out.alreadyDoneNote = i.alreadyDoneNote ?? r.alreadyDoneNote
        return out
    }

    // MARK: Committing

    /// Everything committing a plan entails, in one place.
    ///
    /// This used to be spread across the callers, and they disagreed: the Day
    /// Planner button scheduled reminders but never the timing nudges, the
    /// overnight pass scheduled neither the nudges nor the traffic re-check.
    /// The nudge chain therefore did not exist on any day the user planned from
    /// the planner page — which looked exactly like the notifications being
    /// broken.
    @MainActor
    static func commit(_ result: Result, on date: Date, context: ModelContext,
                       hasGymToday: Bool = false, gymMinute: Int? = nil) async {
        let day = date.startOfDay
        // Fresh-fetch, NOT an @Query snapshot: inside one agentic turn the view
        // never re-renders, so the snapshot predates a state a set_gym/plan_day
        // tool already inserted for this day — and reading it would insert a
        // SECOND row, splitting the gym flag and the plan across two records.
        let state = DailyPlanState.fetchOrCreate(for: day, in: context,
                                                 hasGymToday: hasGymToday, gymMinute: gymMinute)
        state.storePlan(result.plan, isOffline: result.isOffline)
        // A freshly built plan is by definition current again.
        state.planStaleSince = nil
        state.planStaleReason = nil
        context.saveOrLog("plan.commit")
        // Reminders for the key blocks…
        await NotificationService.reschedule(plan: result.plan, on: day)
        // …the timing nudges for the measurable ones, held in a chain so only
        // the block you're actually up to gets one…
        await ActivityTimekeeper.scheduleDay(plan: result.plan, on: day, context: context)
        // …and a background traffic re-check ~90 min before the next commute.
        CommuteBackgroundRefresh.scheduleNext(context: context)
    }

    /// Same as `generate`, but records a diagnostics log (duration + outcome,
    /// with a pending record up front so a generation that never returns is
    /// still captured). Views use this; tests/eval call `generate` directly.
    static func generateLogged(_ inputs: Inputs, context: ModelContext, trigger: PlanGenTrigger) async -> Result {
        let started = Date()
        let log = PlanDiagnostics.begin(trigger: trigger, context: context)
        let result = await generate(inputs)
        PlanDiagnostics.finish(log, isOffline: result.isOffline, retryCount: result.retryCount,
                               commuteMs: result.commuteMs, claudeMs: result.claudeMs,
                               errorClass: result.error, startedAt: started, context: context)
        // Mirror state + diagnostics to iCloud Drive for hands-free reading.
        // Skip the heavy raw-SQLite copy on this per-generation path (which fires
        // on every planner tap / chat plan / overnight auto-plan) — launch and
        // background refresh that. This covers the auto-plan BGTask for free,
        // since it also routes through generateLogged.
        SyncOutbox.exportAll(context: context, includeRawBackup: false)
        return result
    }

    /// Generates a plan, preferring Claude and falling back to the deterministic
    /// engine if the API is unreachable or errors. The Claude plan is validated
    /// against the scheduler's rules; a plan with a SEVERE violation (dropped
    /// Must-do, wasted afternoon, overlap, out-of-bounds work) is retried once
    /// with the problems fed back, and the cleaner of the two is kept.
    static func generate(_ raw: Inputs) async -> Result {
        // Work out what kind of plan this is BEFORE anything else looks at the
        // inputs, so no path can skip it.
        let inputs = resolved(raw)
        var result = await generateResolved(inputs)
        result.resumedFromMinute = inputs.replanFromMinute
        result.keptBlocks = inputs.lockedBlocks.count
        return result
    }

    private static func generateResolved(_ inputs: Inputs) async -> Result {
        let t0 = Date()
        let request = await buildRequest(inputs)   // Maps commute lookups happen here
        let commuteMs = Int(Date().timeIntervalSince(t0) * 1000)

        let tClaude = Date()
        let first: GeneratedPlan
        do {
            first = try await PlanGenerationService.generate(request)
        } catch {
            // Offline: even a mid-day re-plan must keep the locked (already-elapsed)
            // morning — merge it with the deterministic remainder from `from`, not
            // rebuild the whole day (which would discard what's already done).
            let offlinePlan: GeneratedPlan
            if let from = inputs.replanFromMinute {
                let full = deterministic(inputs)
                let remainder = full.blocks.filter { ($0.startMinute ?? 0) >= from }
                offlinePlan = GeneratedPlan(blocks: inputs.lockedBlocks + remainder,
                                            dropped: full.dropped, shrunk: full.shrunk,
                                            summary: full.summary, boundaryTime: full.boundaryTime)
            } else {
                offlinePlan = deterministic(inputs)
            }
            // The ACTUAL error, not a generic shrug: "Request failed (429):
            // rate limited" and "missing API key" need entirely different
            // responses, and the diagnostics log was recording both as
            // "planning service unreachable".
            let detail = (error as? PlanGenerationError)?.errorDescription
                ?? error.localizedDescription
            return Result(plan: offlinePlan, isOffline: true, error: detail,
                          commuteMs: commuteMs, claudeMs: Int(Date().timeIntervalSince(tClaude) * 1000))
        }
        // A mid-day re-plan produces only the REMAINDER; stitch the preserved
        // (already-elapsed) blocks back on and validate the whole merged plan —
        // with the re-plan relaxations (lunch window past its time, midday-event
        // rule). The structural invariants (non-overlap seam, events present,
        // lunch-still-present while reachable) are still enforced and repaired.
        if let from = inputs.replanFromMinute {
            func merge(_ remainder: GeneratedPlan) -> GeneratedPlan {
                GeneratedPlan(blocks: inputs.lockedBlocks + remainder.blocks,
                              dropped: remainder.dropped, shrunk: remainder.shrunk,
                              summary: remainder.summary, boundaryTime: remainder.boundaryTime)
            }
            let elapsed = { Int(Date().timeIntervalSince(tClaude) * 1000) }
            let mergedFirst = merge(first)
            let v = PlanValidation.severe(mergedFirst, request: request, replanNowMinute: from)
            if v.isEmpty {
                return Result(plan: mergedFirst, isOffline: false, error: nil, commuteMs: commuteMs, claudeMs: elapsed())
            }
            // One repair pass, same as the normal path.
            let repairRequest = requestWithCorrections(request, violations: v)
            guard let repaired = try? await PlanGenerationService.generate(repairRequest) else {
                return Result(plan: mergedFirst, isOffline: false, error: nil, commuteMs: commuteMs, claudeMs: elapsed())
            }
            let mergedRepaired = merge(repaired)
            let rv = PlanValidation.severe(mergedRepaired, request: request, replanNowMinute: from)
            let best = rv.count <= v.count ? mergedRepaired : mergedFirst
            return Result(plan: best, isOffline: false, error: nil, retryCount: 1, commuteMs: commuteMs, claudeMs: elapsed())
        }
        let firstViolations = PlanValidation.severe(first, request: request)
        if firstViolations.isEmpty {
            return Result(plan: first, isOffline: false, error: nil,
                          commuteMs: commuteMs, claudeMs: Int(Date().timeIntervalSince(tClaude) * 1000))
        }

        // One repair pass: tell the model exactly what was wrong.
        let repairRequest = requestWithCorrections(request, violations: firstViolations)
        guard let repaired = try? await PlanGenerationService.generate(repairRequest) else {
            return Result(plan: first, isOffline: false, error: nil, // keep the first plan if the retry can't run
                          commuteMs: commuteMs, claudeMs: Int(Date().timeIntervalSince(tClaude) * 1000))
        }
        let repairedViolations = PlanValidation.severe(repaired, request: request)
        let best = repairedViolations.count <= firstViolations.count ? repaired : first
        return Result(plan: best, isOffline: false, error: nil, retryCount: 1,
                      commuteMs: commuteMs, claudeMs: Int(Date().timeIntervalSince(tClaude) * 1000))
    }

    private static func requestWithCorrections(_ req: PlanRequest, violations: [PlanValidation.Violation]) -> PlanRequest {
        var r = req
        let list = violations.map { "- \($0.message)" }.joined(separator: "\n")
        let prefix = req.userMessage.isEmpty ? "" : req.userMessage + "\n\n"
        r.userMessage = prefix + "IMPORTANT: your previous plan for this day broke these rules. Produce a corrected plan that fixes ALL of them:\n\(list)"
        return r
    }

    // MARK: Request assembly (live Maps commute legs)

    /// When each commute leg actually departs, as minutes-since-midnight on the
    /// plan date, derived from the anchors. Feeding these to the Routes API
    /// gets PREDICTED traffic for that time of day instead of traffic at the
    /// moment the plan is generated (planning at night for a midday leg would
    /// otherwise price in empty roads). Pure and unit-tested.
    ///
    /// Event legs are checked FIRST, with the exact label shapes buildRequest
    /// constructs — so a calendar event literally titled "Gym" (a common
    /// calendar entry) is priced by ITS times, not mistaken for the gym-anchor
    /// commute.
    static func legDepartureMinute(label: String, gymMinute: Int?, events: [DailyEvent]) -> Int? {
        for e in events where !e.isAllDay {   // all-day events have no commute
            if label == "\(e.title)→Home" { return e.endMinute }
            for kind in LocationKind.allCases where label == "\(kind.rawValue)→\(e.title)" {
                return e.startMinute - 45   // leave ~45 min before the event
            }
        }
        if label == "Home→Gym", let g = gymMinute {
            return g - 50   // 30 commute + 20 mobility before the weights start
        }
        if label == "Gym→Home", let g = gymMinute {
            return g + 70 + 35   // weights + cardio, then drive home
        }
        return nil
    }

    /// The blocks of an existing plan that have fully elapsed by `minute` — the
    /// part of the day to PRESERVE verbatim across a mid-day re-plan. Excludes
    /// wrap-around blocks (Sleep 23:00→07:00, whose end < start) so they aren't
    /// mistaken for already-done. Pure + unit-tested.
    /// Minutes at which the day still expects you to ARRIVE somewhere — the
    /// only thing a preserved commute can legitimately be delivering you to.
    /// A Home→Gym commute meets MOBILITY, which starts 20 min before the
    /// weightlifting time the user actually enters, so both count.
    static func arrivalAnchors(gymMinute: Int?, eventStarts: [Int]) -> [Int] {
        var out = eventStarts
        if let g = gymMinute {
            out.append(g)
            out.append(g - 20)
        }
        return out
    }

    /// The blocks a mid-day re-plan may preserve verbatim.
    ///
    /// Elapsed is not automatically preservable. Moving the gym from morning
    /// to evening used to leave the morning "Commute Home → Gym" locked in as
    /// already-done — it had elapsed, so it locked — and the new plan then
    /// built the evening gym *around* a journey to a gym it no longer visited
    /// that morning. The day read "18-min trip to arrive for mobility"
    /// followed by interview prep, with no gym anywhere near it.
    ///
    /// So a commute is preserved only while the arrival it was for is still on
    /// the day. `stillArrivingAt` is that set (see `arrivalAnchors`); passing
    /// an empty array means nothing is anchored today, which makes every
    /// elapsed commute orphaned by definition. `nil` disables the check.
    static func lockedBlocks(_ plan: GeneratedPlan, endedBy minute: Int,
                             stillArrivingAt anchors: [Int]?,
                             tolerance: Int = 25) -> [GeneratedBlock] {
        let elapsed = plan.blocks.filter {
            guard let s = $0.startMinute, let e = $0.endMinute else { return false }
            return s <= e && e <= minute
        }
        guard let anchors else { return elapsed }
        return elapsed.filter { block in
            guard block.kind.lowercased() == "commute", let end = block.endMinute else { return true }
            return anchors.contains { abs($0 - end) <= tolerance }
        }
    }

    /// A concrete Date on `day` at wall-clock `minuteOfDay` (bySettingHour, so
    /// a 13:30 leg means 13:30 local even across a DST transition — elapsed-
    /// minute arithmetic would drift an hour on changeover days).
    static func departureDate(minuteOfDay: Int, on day: Date) -> Date? {
        let m = max(0, minuteOfDay)
        return Calendar.current.date(bySettingHour: (m / 60) % 24, minute: m % 60, second: 0, of: day.startOfDay)
    }

    typealias CommuteLeg = (label: String, from: String, to: String, departure: Date?)

    /// The commute legs a day's anchors require, each with its scheduled
    /// departure on the plan date. Pure — split out of buildRequest so the
    /// wiring (labels ↔ departures) is unit-testable without network.
    static func commuteLegs(_ i: Inputs) -> [CommuteLeg] {
        var legs: [CommuteLeg] = []
        let homeAddr = i.locations.first { $0.kind == .home }?.address ?? ""
        let gymAddr = i.locations.first { $0.kind == .gym }?.address ?? ""
        func departure(for label: String) -> Date? {
            guard let minute = legDepartureMinute(label: label, gymMinute: i.hasGym ? i.gymMinute : nil, events: i.events) else { return nil }
            return departureDate(minuteOfDay: minute, on: i.planDate)
        }
        if i.hasGym, !homeAddr.isEmpty, !gymAddr.isEmpty {
            legs.append(("Home→Gym", homeAddr, gymAddr, departure(for: "Home→Gym")))
            legs.append(("Gym→Home", gymAddr, homeAddr, departure(for: "Gym→Home")))
        }
        for e in i.events where !e.destinationAddress.isEmpty {
            let fromAddr = i.locations.first { $0.kind == e.outboundStart }?.address ?? homeAddr
            if !fromAddr.isEmpty {
                let label = "\(e.outboundStart.rawValue)→\(e.title)"
                legs.append((label, fromAddr, e.destinationAddress, departure(for: label)))
            }
            if !homeAddr.isEmpty {
                let label = "\(e.title)→Home"
                legs.append((label, e.destinationAddress, homeAddr, departure(for: label)))
            }
        }
        return legs
    }

    private static func buildRequest(_ i: Inputs) async -> PlanRequest {
        let commutes = await GoogleMapsService.commuteEstimates(legs: commuteLegs(i))

        return PlanRequest(
            userMessage: i.userMessage,
            hasGymToday: i.hasGym,
            gymMinute: i.gymMinute,
            events: i.events.sorted { $0.startMinute < $1.startMinute },
            locations: i.locations,
            defaultCommuteMinutes: 30,
            commuteEstimates: commutes,
            prepNeglectNote: prepNeglectNote(i.prepSessions),
            adherenceNote: i.adherenceNote,
            replanFromMinute: i.replanFromMinute,
            alreadyDoneNote: i.alreadyDoneNote,
            routine: i.routine,
            gymSession: i.gymSession,
            referenceNow: i.referenceNow,
            blankDay: i.blankDay
        )
    }

    // MARK: Deterministic offline fallback

    static func deterministic(_ i: Inputs) -> GeneratedPlan {
        var blocks = DayPlanner.generate(
            gymMinute: i.hasGym ? i.gymMinute : nil,
            prepSessions: i.prepSessions,
            leisureLogs: [],
            // The offline engine sized the gym from the frozen defaults even
            // after the parts became editable — so turning cardio off changed
            // the online plan and not the fallback.
            gymSession: i.gymSession,
            routine: i.routine,
            // A cleared day stays cleared. Without this the leftover hours come
            // back as "Discretionary time — suggested: Music", which is still
            // the planner deciding what the evening is for.
            fillFreeTime: !i.blankDay
        )
        // The offline engine is event-blind by construction, and it used to
        // stay that way: a fallback plan cheerfully scheduled interview prep
        // on top of a 2 PM appointment. Timed events are immovable reality —
        // carve them in as anchors, drop whatever they overlap (reported,
        // never silent), and say plainly that commutes are NOT included.
        let timed = i.events
            .filter { !$0.isAllDay && $0.endMinute > $0.startMinute }
            .sorted { $0.startMinute < $1.startMinute }
        var droppedForEvents: [String] = []
        if !timed.isEmpty {
            blocks = blocks.filter { b in
                let collides = timed.contains { e in
                    b.startMinute < e.endMinute && e.startMinute < b.endMinute
                }
                if collides { droppedForEvents.append(b.title) }
                return !collides
            }
        }
        var generated = blocks.map { b in
            GeneratedBlock(
                title: b.title,
                startTime: String(format: "%02d:%02d", b.startMinute / 60, b.startMinute % 60),
                endTime: String(format: "%02d:%02d", b.endMinute / 60, b.endMinute % 60),
                note: b.note,
                isAnchor: b.isAnchor,
                kind: b.isAnchor ? "anchor" : "activity"
            )
        }
        for e in timed {
            generated.append(GeneratedBlock(
                title: e.title,
                startTime: String(format: "%02d:%02d", e.startMinute / 60, e.startMinute % 60),
                endTime: String(format: "%02d:%02d", e.endMinute / 60, e.endMinute % 60),
                note: e.destinationAddress.isEmpty ? nil
                    : "At \(e.destinationAddress). Offline plan — commute NOT included, leave early.",
                isAnchor: true,
                kind: "event"
            ))
        }
        generated.sort { ($0.startMinute ?? 0) < ($1.startMinute ?? 0) }
        let eventNote = timed.isEmpty ? ""
            : " Your \(timed.count) timed event(s) are carved in as fixed anchors; commutes could not be measured offline — leave earlier than feels safe."
        return GeneratedPlan(
            blocks: generated, dropped: droppedForEvents, shrunk: [],
            summary: "Offline plan from the built-in scheduler.\(eventNote)", boundaryTime: nil
        )
    }

    static func prepNeglectNote(_ prepSessions: [PrepSession]) -> String? {
        let categories: [PrepCategory] = [.productSense, .execution, .strategy, .behavioral]
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let recent = prepSessions.filter { $0.date >= weekAgo && $0.category != .reading }
        let counts = Dictionary(grouping: recent, by: { $0.category }).mapValues(\.count)
        let ranked = categories.sorted { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
        return "Fewest practice sessions this week (most neglected first): " + ranked.map(\.rawValue).joined(separator: ", ")
    }
}
