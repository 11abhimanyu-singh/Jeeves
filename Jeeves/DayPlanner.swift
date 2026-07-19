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
    static let dayStartMinute = 8 * 60          // 8:00 AM
    static let dayEndMinute = 20 * 60 + 30       // 8:30 PM
    static let photographyMinutes = 30
    static let lunchDeadlineMinute = 14 * 60 + 30 // 2:30 PM — Lunch must start at or before this
    // Below this, a leftover gap isn't worth scheduling as an activity — a
    // 1-minute "Discretionary time" block makes no sense, so we drop it and
    // leave the gap. Better to under-fill than to cram.
    static let minDiscretionaryMinutes = 20
    // commute + mobility + weights + cardio + commute + shower — the full span
    // from leaving for the gym to being ready afterward.
    static let gymToShowerDuration = 30 + 20 + 70 + 35 + 30 + 20

    private typealias QueueItem = (title: String, minutes: Int, note: String?, category: PrepCategory?)

    /// - Parameters:
    ///   - gymMinute: minutes-since-midnight for today's weightlifting start, or nil for a rest day.
    static func generate(gymMinute: Int?, prepSessions: [PrepSession], leisureLogs: [LeisureLog]) -> [PlanBlock] {
        var blocks: [PlanBlock] = []
        var cursor = dayStartMinute

        // Fixed morning anchor — always first, your stated peak-focus slot.
        blocks.append(PlanBlock(title: "Interview prep — Reading", startMinute: cursor, durationMinutes: 90, note: "Peak focus slot", isAnchor: true, prepCategory: .reading))
        cursor += 90
        blocks.append(PlanBlock(title: "Chores", startMinute: cursor, durationMinutes: 40, note: nil, isAnchor: false))
        cursor += 40
        let choresEnd = cursor

        // Movable, fixed-duration queue — order matters, it's the fill order.
        var queue: [QueueItem] = [
            ("Job applications", 90, nil, nil),
            ("Reading (habit)", 90, nil, nil),
            ("Lunch", 45, nil, nil),
            ("Chore buffer", 30, nil, nil),
        ]
        queue.append(contentsOf: practiceQueue(from: prepSessions))

        guard let gymMinute else {
            // Rest day: drain the queue (Lunch still deadline-protected), fill leftover with discretionary time, Photography last.
            let packed = packQueue(queue, cursor: cursor, pool: nil)
            blocks.append(contentsOf: packed.blocks)
            cursor = packed.cursor
            let photographyStart = dayEndMinute - photographyMinutes
            let slack = photographyStart - cursor
            if slack >= minDiscretionaryMinutes {
                let suggested = mostNeglectedLeisure(leisureLogs: leisureLogs, excluding: .photography)
                blocks.append(PlanBlock(title: "Discretionary time", startMinute: cursor, durationMinutes: slack, note: "Suggested: \(suggested.rawValue) — least recently logged", isAnchor: false, leisureActivity: suggested))
                cursor += slack
            }
            blocks.append(PlanBlock(title: "Photography", startMinute: photographyStart, durationMinutes: photographyMinutes, note: "Fixed end-of-day block", isAnchor: true, leisureActivity: .photography))
            return blocks
        }

        let leaveTime = gymMinute - 20 - 30 // mobility + commute, worked backward from weights start
        let preGymPool = max(0, leaveTime - choresEnd)

        // Where the post-gym region begins. If that's already past lunch's 2:30 PM
        // deadline, lunch can't live after the gym — it must be seated pre-gym.
        let postGymStart = leaveTime + gymToShowerDuration
        let lunchMustBePreGym = postGymStart > lunchDeadlineMinute

        let packed = packQueue(queue, cursor: choresEnd, pool: preGymPool, lunchMustFitInPool: lunchMustBePreGym)
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

        // Gym block — the pivot.
        var gymCursor = leaveTime
        blocks.append(PlanBlock(title: "Commute to gym", startMinute: gymCursor, durationMinutes: 30, note: nil, isAnchor: false))
        gymCursor += 30
        blocks.append(PlanBlock(title: "Mobility", startMinute: gymCursor, durationMinutes: 20, note: nil, isAnchor: false))
        gymCursor += 20
        blocks.append(PlanBlock(title: "Weightlifting", startMinute: gymCursor, durationMinutes: 70, note: "Anchor time", isAnchor: true))
        gymCursor += 70
        blocks.append(PlanBlock(title: "Cardio", startMinute: gymCursor, durationMinutes: 35, note: nil, isAnchor: false))
        gymCursor += 35
        blocks.append(PlanBlock(title: "Commute home", startMinute: gymCursor, durationMinutes: 30, note: nil, isAnchor: false))
        gymCursor += 30

        blocks.append(PlanBlock(title: "Shower", startMinute: gymCursor, durationMinutes: 20, note: nil, isAnchor: false))
        gymCursor += 20

        for item in overflow {
            blocks.append(PlanBlock(title: item.title, startMinute: gymCursor, durationMinutes: item.minutes, note: item.note, isAnchor: false, prepCategory: item.category))
            gymCursor += item.minutes
        }

        let photographyStart = dayEndMinute - photographyMinutes
        let postGymSlack = photographyStart - gymCursor
        if postGymSlack >= minDiscretionaryMinutes {
            let suggested = mostNeglectedLeisure(leisureLogs: leisureLogs, excluding: .photography)
            blocks.append(PlanBlock(title: "Discretionary time", startMinute: gymCursor, durationMinutes: postGymSlack, note: "Suggested: \(suggested.rawValue) — least recently logged", isAnchor: false, leisureActivity: suggested))
            gymCursor += postGymSlack
        }
        blocks.append(PlanBlock(title: "Photography", startMinute: photographyStart, durationMinutes: photographyMinutes, note: "Fixed end-of-day block", isAnchor: true, leisureActivity: .photography))

        return blocks
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
            (title: "Interview prep — \(cat.rawValue)", minutes: mins, note: "\(counts[cat] ?? 0) sessions logged this week", category: cat)
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

            if let pool, filled + item.minutes > pool {
                overflow.append(item)
            } else {
                blocks.append(PlanBlock(title: item.title, startMinute: cursor, durationMinutes: item.minutes, note: item.note, isAnchor: false, prepCategory: item.category))
                cursor += item.minutes
                filled += item.minutes
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
