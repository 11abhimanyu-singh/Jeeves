//
//  DayPlanner.swift
//  Jeeves
//
//  Deterministic scheduling engine implementing the gym-pivot algorithm:
//  fixed-duration blocks get packed forward from 8:00 AM and, once a gym
//  time is set, split around the gym's leave-time as a pivot. Interview
//  practice and discretionary time are weighted by what's been neglected
//  in your logged history — this is the seed for a future Claude-powered
//  version, but works standalone for now.
//
//  Each block that feeds the weighting algorithm carries its prepCategory
//  or leisureActivity directly, so the view can log completion accurately
//  without guessing from the title string.
//

import Foundation

struct PlanBlock: Identifiable {
    let id = UUID()
    let title: String
    let startMinute: Int   // minutes since 12:00 AM
    let durationMinutes: Int
    let note: String?
    let isAnchor: Bool
    var prepCategory: PrepCategory? = nil
    var leisureActivity: DiscretionaryActivity? = nil

    var endMinute: Int { startMinute + durationMinutes }

    var timeRangeLabel: String {
        "\(DayPlanner.label(for: startMinute)) – \(DayPlanner.label(for: endMinute))"
    }

    /// True for blocks that feed the neglect-weighting algorithm and can be
    /// logged as done. Everything else (gym, reading, lunch, chores...) is
    /// display-only for now.
    var isLoggable: Bool { prepCategory != nil || leisureActivity != nil }
}

enum DayPlanner {
    /// Set in Settings; 8:00 until it is. One source, because this used to be
    /// a `static let` here AND in Baseline, with a third derivation in the
    /// prompt builder.
    static var dayStartMinute: Int { DayPreferences.dayStartMinute }
    static let dayEndMinute = 20 * 60 + 30       // 8:30 PM — end of the productive window
    static let sleepMinute = 23 * 60             // 11:00 PM — fixed bedtime anchor
    static let photographyMinutes = 30
    static let lunchEarliestMinute = 12 * 60 + 30 // 12:30 PM — Lunch never starts before this
    static let lunchDeadlineMinute = 14 * 60 + 30 // 2:30 PM — Lunch must start at or before this (finish by 14:00 preferred)
    // Below this, a leftover gap isn't worth scheduling as an activity — a
    // 1-minute "Discretionary time" block makes no sense, so we drop it and
    // leave the gap. Better to under-fill than to cram.
    static let minDiscretionaryMinutes = 20
    // commute + mobility + weights + cardio + commute + shower — the full span
    // from leaving for the gym to being ready afterward.
    static let commuteToGymMinutes = 30
    static let commuteHomeMinutes = 30
    static let showerMinutes = 20

    /// The gym trip's shape. `outbound` carries the parking buffer; the trip
    /// home does not. `workout` is one block: mobility, weightlifting and
    /// cardio are logged in Fitness, so splitting them across the day plan
    /// only added rows the planner had to reason about and the user never
    /// used. The routine still holds the parts — they set the LENGTH.
    static func gymSpan(_ session: [(name: String, minutes: Int)])
        -> (outbound: Int, workout: Int, total: Int) {
        let outbound = commuteToGymMinutes + CommuteBuffer.parkingMinutes
        let workout = session.map(\.minutes).reduce(0, +)
        return (outbound, workout, outbound + workout + commuteHomeMinutes + showerMinutes)
    }

    /// The historical fixed session, kept for callers that don't configure one.
    static var gymToShowerDuration: Int { gymSpan(Baseline.gymParts).total }

    private typealias QueueItem = (title: String, minutes: Int, note: String?,
                                   category: PrepCategory?, tier: PriorityTier)

    /// The routine, in the routine's OWN order, as queue items.
    ///
    /// The first block used to be a hardcoded "Interview prep — Reading" pinned
    /// to the day start, which outranked whatever the user had actually put
    /// first in their routine — so a routine with Chores at the top still
    /// opened with reading.
    ///
    /// The four practice categories are not four independent rows here: their
    /// minutes are re-weighted daily by what's been neglected, so they arrive
    /// together, at the position of whichever one the routine lists first. Both
    /// shapes are handled — the single legacy "Interview prep — practice" row
    /// and the four grouped children that replaced it.
    private static func routineQueue(_ routine: [BaselineActivity],
                                     prepSessions: [PrepSession]) -> [QueueItem] {
        var out: [QueueItem] = []
        var practiceSeated = false
        for a in routine {
            let isReading = a.name.localizedCaseInsensitiveContains("reading")
            if PlanRules.isPrepBlock(title: a.name), !isReading {
                if !practiceSeated {
                    out.append(contentsOf: practiceQueue(from: prepSessions))
                    practiceSeated = true
                }
                continue
            }
            // Prep reading logs against the reading CATEGORY; the reading habit
            // is the library and logs against neither.
            let category: PrepCategory? =
                (isReading && a.name.localizedCaseInsensitiveContains("interview prep")) ? .reading : nil
            out.append((title: a.name, minutes: a.durationMinutes, note: a.note,
                        category: category, tier: a.tier))
        }
        return out
    }

    /// - Parameters:
    ///   - gymMinute: minutes-since-midnight for today's weightlifting start, or nil for a rest day.
    ///   - routine: the user's activities in fill order. The planner follows it
    ///     rather than a list frozen in this file.
    ///   - fillFreeTime: false for a day the user deliberately emptied — the
    ///     leftover hours stay empty instead of coming back as "Discretionary
    ///     time", which is still the planner deciding what the evening is for.
    static func generate(gymMinute: Int?, prepSessions: [PrepSession], leisureLogs: [LeisureLog],
                         gymSession: [(name: String, minutes: Int)] = Baseline.gymParts,
                         routine: [BaselineActivity] = Baseline.activities,
                         fillFreeTime: Bool = true) -> [PlanBlock] {
        var blocks: [PlanBlock] = []
        var cursor = dayStartMinute

        // Second-half gym (weightlifting at/after the 14:15 window midpoint) means
        // the day would otherwise start unshowered — add a short morning shower
        // (the post-gym shower still happens later).
        if let gymMinute, gymMinute >= (dayStartMinute + dayEndMinute) / 2 {
            blocks.append(PlanBlock(title: "Shower", startMinute: cursor, durationMinutes: 20, note: "Morning shower — gym is later today", isAnchor: false))
            cursor += 20
        }
        let morningEnd = cursor

        // Movable, fixed-duration queue — order matters, it's the fill order,
        // and it is now the user's order rather than this file's.
        let queue = routineQueue(routine, prepSessions: prepSessions)

        guard let gymMinute else {
            // Rest day: drain the queue (Lunch still deadline-protected), fill leftover with discretionary time.
            let packed = packQueue(queue, cursor: cursor, pool: nil)
            blocks.append(contentsOf: packed.blocks)
            cursor = packed.cursor
            let slack = dayEndMinute - cursor
            if fillFreeTime, slack >= minDiscretionaryMinutes {
                let suggested = mostNeglectedLeisure(leisureLogs: leisureLogs, excluding: .photography)
                blocks.append(PlanBlock(title: "Discretionary time", startMinute: cursor, durationMinutes: slack, note: "Suggested: \(suggested.rawValue) — least recently logged", isAnchor: false, leisureActivity: suggested))
                cursor += slack
            }
            appendEvening(&blocks, from: cursor)
            return blocks
        }

        // The gym time is when the SESSION starts, so leaving is just the drive
        // plus parking worked backward from it. Neither is negotiable: the day
        // gets shorter before the trip does.
        let span = gymSpan(gymSession)
        let leaveTime = gymMinute - span.outbound
        let preGymPool = max(0, leaveTime - morningEnd)

        // Where the post-gym region begins. If that's already past lunch's 2:30 PM
        // deadline, lunch can't live after the gym — it must be seated pre-gym.
        let postGymStart = leaveTime + span.total
        let lunchMustBePreGym = postGymStart > lunchDeadlineMinute

        let packed = packQueue(queue, cursor: morningEnd, pool: preGymPool, lunchMustFitInPool: lunchMustBePreGym)
        blocks.append(contentsOf: packed.blocks)
        var preGymCursor = packed.cursor

        // If lunch still spilled to overflow, make it the first post-gym block so
        // it starts at postGymStart — which is at or before the deadline whenever
        // it wasn't forced pre-gym above.
        var overflow = packed.overflow
        if let lunchIndex = overflow.firstIndex(where: { $0.title == "Lunch" }) {
            overflow.insert(overflow.remove(at: lunchIndex), at: 0)
        }

        if leaveTime > preGymCursor {
            blocks.append(PlanBlock(title: "Slack", startMinute: preGymCursor, durationMinutes: leaveTime - preGymCursor, note: nil, isAnchor: false))
            preGymCursor = leaveTime
        }

        // Gym block — the pivot. Floor the departure at where the morning blocks
        // actually ended: for an unrealistically early gym (leaveTime before the
        // fixed morning finishes) starting at leaveTime would overlap them, so the
        // gym slides to the earliest slot that keeps the day in chronological order.
        var gymCursor = max(leaveTime, preGymCursor)
        // Outbound carries the parking buffer; the trip home does not.
        blocks.append(PlanBlock(title: "Commute to gym", startMinute: gymCursor, durationMinutes: span.outbound,
                                note: "\(commuteToGymMinutes) min drive + \(CommuteBuffer.parkingMinutes) min parking", isAnchor: false))
        gymCursor += span.outbound
        // ONE block. What happens inside the session is logged in Fitness.
        let parts = gymSession.map { "\($0.name) \($0.minutes)m" }.joined(separator: " · ")
        blocks.append(PlanBlock(title: "Gym", startMinute: gymCursor,
                                durationMinutes: span.workout,
                                note: parts.isEmpty ? "Anchor time" : parts,
                                isAnchor: true))
        gymCursor += span.workout
        blocks.append(PlanBlock(title: "Commute home", startMinute: gymCursor, durationMinutes: commuteHomeMinutes, note: nil, isAnchor: false))
        gymCursor += commuteHomeMinutes

        blocks.append(PlanBlock(title: "Shower", startMinute: gymCursor, durationMinutes: 20, note: nil, isAnchor: false))
        gymCursor += 20

        // The post-gym region places overflow itself rather than going back
        // through packQueue, so the breather has to be honoured here too —
        // this is where the prep blocks land on a gym day.
        var lastWasPrep = false
        for item in overflow {
            // Lunch is never seated before 12:30, even when the gym ended early.
            var placeAt = gymCursor
            if item.title == "Lunch", placeAt < lunchEarliestMinute { placeAt = lunchEarliestMinute }
            let isPrep = PlanRules.isPrepBlock(title: item.title)
            if lastWasPrep, isPrep, placeAt == gymCursor {
                let breather = PlanRules.prepBreatherMinutes
                guard placeAt + breather + item.minutes <= dayEndMinute else { continue }
                blocks.append(PlanBlock(title: "Breather", startMinute: placeAt,
                                        durationMinutes: breather,
                                        note: "switching subject", isAnchor: false))
                placeAt += breather
            }
            // Don't pack past the 20:30 boundary — drop what won't fit.
            guard placeAt + item.minutes <= dayEndMinute else { continue }
            blocks.append(PlanBlock(title: item.title, startMinute: placeAt, durationMinutes: item.minutes, note: item.note, isAnchor: false, prepCategory: item.category))
            gymCursor = placeAt + item.minutes
            lastWasPrep = isPrep
        }

        let postGymSlack = dayEndMinute - gymCursor
        if fillFreeTime, postGymSlack >= minDiscretionaryMinutes {
            let suggested = mostNeglectedLeisure(leisureLogs: leisureLogs, excluding: .photography)
            blocks.append(PlanBlock(title: "Discretionary time", startMinute: gymCursor, durationMinutes: postGymSlack, note: "Suggested: \(suggested.rawValue) — least recently logged", isAnchor: false, leisureActivity: suggested))
            gymCursor += postGymSlack
        }

        appendEvening(&blocks, from: gymCursor)
        return blocks
    }

    /// Caps every day the same way: a wind-down / personal-time block from the
    /// end of the productive window (20:30) to the fixed 23:00 bedtime, then a
    /// Sleep anchor. Work never runs past 20:30, but the evening is real time
    /// the user still lives in — and Sleep gets a reminder like any anchor.
    private static func appendEvening(_ blocks: inout [PlanBlock], from lastEnd: Int) {
        let windDownStart = min(lastEnd, sleepMinute)
        if sleepMinute - windDownStart >= minDiscretionaryMinutes {
            // On a cleared day this block IS the day, so it opens at 08:00 —
            // and calling that "Evening" reads as a bug rather than an empty
            // day. Say what's true instead.
            let note = windDownStart < dayEndMinute
                ? "Nothing scheduled — the day is yours"
                : "Evening — no scheduled work"
            blocks.append(PlanBlock(title: "Wind-down / personal time", startMinute: windDownStart, durationMinutes: sleepMinute - windDownStart, note: note, isAnchor: false))
        }
        blocks.append(PlanBlock(title: "Sleep", startMinute: sleepMinute, durationMinutes: 8 * 60, note: "11 PM – 7 AM", isAnchor: true))
    }

    /// Splits the 120-min practice block across the 4 categories, weighting
    /// toward whichever has the fewest logged sessions this week.
    private static func practiceQueue(from sessions: [PrepSession]) -> [QueueItem] {
        let categories: [PrepCategory] = [.productSense, .execution, .strategy, .behavioral]
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let recent = sessions.filter { $0.date >= weekAgo && $0.category != .reading }
        let counts = Dictionary(grouping: recent, by: { $0.category }).mapValues { $0.count }

        let sorted = categories.sorted { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
        let minuteAllocation = [45, 35, 25, 15] // most-neglected gets the most time
        return zip(sorted, minuteAllocation).map { cat, mins in
            (title: "Interview prep — \(cat.rawValue)", minutes: mins, note: "\(counts[cat] ?? 0) sessions logged this week", category: cat, tier: .important)
        }
    }

    /// Packs `queue` items forward from `cursor` in order, respecting an optional pool
    /// limit (nil = unbounded); items that don't fit are returned as overflow, in order.
    ///
    /// Lunch gets special treatment because it has a hard 2:30 PM start deadline.
    /// Before committing a non-Lunch item, we check whether doing so would strand
    /// Lunch, and if so seat Lunch first. Two ways an item can strand Lunch:
    ///   - it pushes the clock so far that Lunch placed after it would start late; or
    ///   - (when `lunchMustFitInPool`, i.e. the whole post-gym region is past the
    ///     deadline) it eats the bounded pool room Lunch needs, forcing Lunch into
    ///     a post-gym overflow slot that would be too late.
    private static func packQueue(_ queue: [QueueItem], cursor startCursor: Int, pool: Int?, lunchMustFitInPool: Bool = false) -> (blocks: [PlanBlock], cursor: Int, overflow: [QueueItem]) {
        var cursor = startCursor
        var filled = 0
        var blocks: [PlanBlock] = []
        var overflow: [QueueItem] = []
        var remaining = queue
        let lunchMinutes = queue.first { $0.title == "Lunch" }?.minutes ?? 0
        var lunchPlaced = !queue.contains { $0.title == "Lunch" }
        var lastWasPrep = false

        while !remaining.isEmpty {
            var item = remaining.removeFirst()

            if !lunchPlaced, item.title != "Lunch" {
                let pushesPastDeadline = cursor + item.minutes > lunchDeadlineMinute
                let eatsLunchPoolRoom = lunchMustFitInPool && (pool.map { filled + item.minutes + lunchMinutes > $0 } ?? false)
                if pushesPastDeadline || eatsLunchPoolRoom,
                   let lunchIndex = remaining.firstIndex(where: { $0.title == "Lunch" }) {
                    let lunch = remaining.remove(at: lunchIndex)
                    remaining.insert(item, at: 0)
                    item = lunch
                }
            }

            // A breather between back-to-back prep blocks. The rule lived in
            // the prompt and in PlanValidation, but the offline planner packed
            // Product Sense straight into Execution — a rule the fallback
            // didn't know about is a rule the fallback breaks.
            let needsBreather = lastWasPrep && PlanRules.isPrepBlock(title: item.title)
            let breather = needsBreather ? PlanRules.prepBreatherMinutes : 0

            if let pool, filled + breather + item.minutes > pool {
                // Commute and parking are non-negotiable; the day gets shorter
                // before the trip does. A FLEXIBLE item with real room left
                // gives way by shrinking rather than by moving past the gym —
                // this is the old hardcoded "chores trimmed to leave for the
                // gym on time" rule, generalised to whatever the user put
                // there. Important and Must-do items move instead of shrinking.
                let room = pool - filled - breather
                if item.tier == .flexible, room >= minDiscretionaryMinutes {
                    blocks.append(PlanBlock(title: item.title, startMinute: cursor,
                                            durationMinutes: room,
                                            note: "trimmed to leave on time", isAnchor: false,
                                            prepCategory: item.category))
                    cursor += room
                    filled += room
                    lastWasPrep = PlanRules.isPrepBlock(title: item.title)
                } else {
                    overflow.append(item)
                }
            } else {
                if breather > 0 {
                    blocks.append(PlanBlock(title: "Breather", startMinute: cursor,
                                            durationMinutes: breather,
                                            note: "switching subject", isAnchor: false))
                    cursor += breather
                    filled += breather
                }
                // Lunch is never eaten before 12:30. On rest days (unbounded pool)
                // hold with a short breather so lunch lands in its window; on gym
                // days the pre-gym packing already seats it around the gym.
                if item.title == "Lunch", pool == nil, cursor < lunchEarliestMinute {
                    blocks.append(PlanBlock(title: "Free time", startMinute: cursor, durationMinutes: lunchEarliestMinute - cursor, note: "brief breather before lunch", isAnchor: false))
                    cursor = lunchEarliestMinute
                }
                blocks.append(PlanBlock(title: item.title, startMinute: cursor, durationMinutes: item.minutes, note: item.note, isAnchor: false, prepCategory: item.category))
                cursor += item.minutes
                filled += item.minutes
                lastWasPrep = PlanRules.isPrepBlock(title: item.title)
            }
            if item.title == "Lunch" { lunchPlaced = true }
        }
        return (blocks, cursor, overflow)
    }

    private static func mostNeglectedLeisure(leisureLogs: [LeisureLog], excluding: DiscretionaryActivity? = nil) -> DiscretionaryActivity {
        let activities = DiscretionaryActivity.allCases.filter { $0 != excluding }
        let lastDates = Dictionary(grouping: leisureLogs, by: { $0.activity })
            .mapValues { $0.map(\.date).max() ?? .distantPast }
        return activities.min { (lastDates[$0] ?? .distantPast) < (lastDates[$1] ?? .distantPast) } ?? .music
    }

    static func label(for minuteOfDay: Int) -> String {
        let hour24 = (minuteOfDay / 60) % 24
        let minute = minuteOfDay % 60
        let period = hour24 < 12 ? "AM" : "PM"
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        return String(format: "%d:%02d %@", hour12, minute, period)
    }
}
