//
//  ActivitySession.swift
//  Jeeves
//
//  One attempt at one planned block: when it actually started, how long it
//  actually ran, and how much actually got done.
//
//  The app could already say a block was "done" — you tap it and a string
//  lands in that day's DailyPlanState. But that tick dies there. It writes no
//  PrepSession, so the neglect ranking never sees it; it carries no duration,
//  so planned-vs-actual is unknowable; and it carries no count, so "how much
//  reading did I get through this week" has no answer anywhere in the app.
//
//  A session is the record that answers all three. All properties are
//  defaulted for CloudKit mirroring.
//

import Foundation
import SwiftData

enum ActivityState: String, Codable {
    case running
    case paused
    case done          // stopped by the user
    case needsDetail   // auto-closed; ran, but for how long is not known
    case cancelled     // started by mistake
}

@Model
final class ActivitySession {
    var id: UUID = UUID()
    var day: Date = Date.distantPast          // startOfDay, for the day's roll-up
    /// AdherenceEngine.key(block) — ties the session to the block it belongs to
    /// so a re-plan that keeps the block keeps its session.
    var blockKey: String = ""
    var title: String = ""
    var plannedMinutes: Int = 0

    var startedAt: Date = Date.distantPast
    var endedAt: Date? = nil
    /// Set while paused; nil when running. Elapsed stops climbing meanwhile.
    var pausedAt: Date? = nil
    var pausedSeconds: Double = 0

    var stateRaw: String = ActivityState.running.rawValue
    var unitRaw: String = ""
    var quantity: Int = 0
    /// Distinguishes a real zero ("I read nothing") from silence ("nobody
    /// asked, or I chose to log later"). Without this an unanswered prompt is
    /// indistinguishable from a session that achieved nothing.
    var quantityGiven: Bool = false

    init(day: Date, blockKey: String, title: String, plannedMinutes: Int,
         unit: ActivityUnit? = nil, startedAt: Date = .now) {
        self.id = UUID()
        self.day = day.startOfDay
        self.blockKey = blockKey
        self.title = title
        self.plannedMinutes = plannedMinutes
        self.unitRaw = unit?.rawValue ?? ""
        self.startedAt = startedAt
        self.stateRaw = ActivityState.running.rawValue
    }

    var state: ActivityState {
        get { ActivityState(rawValue: stateRaw) ?? .done }
        set { stateRaw = newValue.rawValue }
    }
    var unit: ActivityUnit? {
        get { unitRaw.isEmpty ? nil : ActivityUnit(rawValue: unitRaw) }
        set { unitRaw = newValue?.rawValue ?? "" }
    }
    var isLive: Bool { state == .running || state == .paused }

    /// Seconds actually spent, paused time removed. Climbs while running,
    /// frozen while paused, fixed once ended.
    func elapsed(asOf now: Date = .now) -> TimeInterval {
        let end = endedAt ?? (pausedAt ?? now)
        return max(0, end.timeIntervalSince(startedAt) - pausedSeconds)
    }

    var actualMinutes: Int { Int((elapsed() / 60).rounded()) }

    /// Positive = ran over the plan. Nil when the duration isn't trustworthy,
    /// which is the whole point of `needsDetail`: an auto-closed session knows
    /// when it started and nothing else.
    var driftMinutes: Int? {
        guard state != .needsDetail, plannedMinutes > 0 else { return nil }
        return actualMinutes - plannedMinutes
    }

    // MARK: transitions

    func pause(at now: Date = .now) {
        guard state == .running else { return }
        pausedAt = now
        state = .paused
    }

    func resume(at now: Date = .now) {
        guard state == .paused, let pausedAt else { return }
        pausedSeconds += max(0, now.timeIntervalSince(pausedAt))
        self.pausedAt = nil
        state = .running
    }

    func stop(at now: Date = .now) {
        guard isLive else { return }
        if state == .paused, let pausedAt {
            pausedSeconds += max(0, now.timeIntervalSince(pausedAt))
        }
        pausedAt = nil
        endedAt = now
        state = .done
    }

    /// Nobody answered. The elapsed time is NOT recorded as fact — you know
    /// when it started and that it ran past its plan, and inventing the rest
    /// is exactly the kind of number the planner would later learn from.
    /// WorkoutWatchdog made this call once already, at four hours.
    func autoClose(at now: Date = .now) {
        guard isLive else { return }
        pausedAt = nil
        endedAt = now
        state = .needsDetail
    }

    func cancel() {
        guard isLive else { return }
        endedAt = .now
        state = .cancelled
    }

    func record(quantity: Int) {
        self.quantity = max(0, quantity)
        quantityGiven = true
    }
}

extension ActivitySession {
    /// The live session, if one is running or paused. There is only ever one:
    /// two clocks competing for the same glance is the thing the Live Activity
    /// design refuses to draw, and the store shouldn't allow it either.
    static func live(in context: ModelContext) -> ActivitySession? {
        ((try? context.fetch(FetchDescriptor<ActivitySession>())) ?? [])
            .first { $0.isLive }
    }

    static func forBlock(key: String, day: Date, in context: ModelContext) -> ActivitySession? {
        let d = day.startOfDay
        return ((try? context.fetch(FetchDescriptor<ActivitySession>())) ?? [])
            .first { $0.blockKey == key && $0.day == d }
    }

    static func onDay(_ day: Date, in context: ModelContext) -> [ActivitySession] {
        let d = day.startOfDay
        return ((try? context.fetch(FetchDescriptor<ActivitySession>())) ?? [])
            .filter { $0.day == d }
            .sorted { $0.startedAt < $1.startedAt }
    }
}
