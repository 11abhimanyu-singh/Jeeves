//
//  ActivityTracker.swift
//  Jeeves
//
//  Starting and finishing a session, and — the part that matters — turning a
//  finished one into EVIDENCE.
//
//  Four of the five measurable block types have no writer in this app. Not a
//  missing feature: a missing row. PrepSession is constructed exactly zero
//  times outside a test fixture, ReadingLog and JobApplication are at zero
//  rows in the live store, and LeisureLog holds one row from setup day. That
//  is why every interview-prep block has been marked skipped since 20 July,
//  and why the planner is told "most neglected: Product Sense" every single
//  morning by a ranking computed over an empty table.
//
//  Logging a session writes the row. That is the fix.
//

import Foundation
import SwiftData

@MainActor
enum ActivityTracker {

    /// Begin a block. Any other live session is stopped first — one clock.
    @discardableResult
    static func start(blockKey: String, title: String, plannedMinutes: Int,
                      day: Date, context: ModelContext) -> ActivitySession? {
        guard let unit = ActivityUnit.forBlock(title: title) else { return nil }

        // Re-entering a block you already logged reopens it rather than
        // minting a second attempt at the same thing.
        if let existing = ActivitySession.forBlock(key: blockKey, day: day, in: context) {
            if existing.isLive { return existing }
            existing.endedAt = nil
            existing.state = .running
            context.saveOrLog("activity.reopen")
            return existing
        }

        if let live = ActivitySession.live(in: context) { finish(live, context: context) }

        let session = ActivitySession(day: day, blockKey: blockKey, title: title,
                                      plannedMinutes: plannedMinutes, unit: unit)
        context.insert(session)
        context.saveOrLog("activity.start")
        EventLog.log(.toolCall, "session started: \(title) (planned \(plannedMinutes)m)",
                     subject: session.id, context: context)
        return session
    }

    /// Stop and record. `quantity` nil means "log later" — the time is kept,
    /// the count stays unknown, and it joins the backfill queue.
    static func finish(_ session: ActivitySession, quantity: Int? = nil,
                       context: ModelContext) {
        session.stop()
        if let quantity { session.record(quantity: quantity) }
        context.saveOrLog("activity.finish")
        writeEvidence(for: session, context: context)
        EventLog.log(.toolCall,
                     "session finished: \(session.title) — \(session.actualMinutes)m of \(session.plannedMinutes)m"
                     + (session.quantityGiven ? ", \(session.quantity) \(session.unit?.short ?? "")" : ", no count given"),
                     subject: session.id, context: context)
    }

    /// Nobody answered the +15 nudge. Close it, keep no invented duration, and
    /// release whatever the chain was holding behind it.
    static func autoClose(_ session: ActivitySession, context: ModelContext) {
        session.autoClose()
        context.saveOrLog("activity.autoClose")
        // Deliberately NO evidence row: a session of unknown length that may
        // not have happened at all is not something to write down as fact.
        EventLog.log(.workoutAutoClosed,
                     "session auto-closed with no duration: \(session.title)",
                     subject: session.id, context: context)
    }

    /// Log a block after the fact — the main path on a busy day, not a
    /// fallback. Creates a completed session with the planned duration as the
    /// honest best estimate, flagged by `quantityGiven` only if a count came.
    @discardableResult
    static func logRetroactively(blockKey: String, title: String, plannedMinutes: Int,
                                 day: Date, quantity: Int?, context: ModelContext) -> ActivitySession? {
        guard let unit = ActivityUnit.forBlock(title: title) else { return nil }
        let session = ActivitySession.forBlock(key: blockKey, day: day, in: context)
            ?? {
                let s = ActivitySession(day: day, blockKey: blockKey, title: title,
                                        plannedMinutes: plannedMinutes, unit: unit,
                                        startedAt: day.startOfDay)
                context.insert(s)
                return s
            }()
        session.endedAt = session.startedAt.addingTimeInterval(Double(plannedMinutes) * 60)
        session.state = .done
        if let quantity { session.record(quantity: quantity) }
        context.saveOrLog("activity.retro")
        writeEvidence(for: session, context: context)
        return session
    }

    /// Editable until the end of the NEXT calendar day. Miss a Friday and open
    /// the app on Monday and it has closed — worth knowing going in.
    static func isWithinBackfillWindow(_ day: Date, now: Date = .now) -> Bool {
        let cal = Calendar.current
        guard let deadline = cal.date(byAdding: .day, value: 2, to: day.startOfDay) else { return false }
        return now < deadline && day.startOfDay <= now.startOfDay
    }

    // MARK: evidence

    /// The row that makes a session visible to the rest of the app: the
    /// neglect ranking, the adherence history, the digest. Without this a
    /// session is a private note to itself.
    private static func writeEvidence(for session: ActivitySession, context: ModelContext) {
        guard session.state == .done else { return }
        let day = session.day
        let minutes = Double(max(session.actualMinutes, 1))
        let t = session.title.lowercased()

        switch session.unit {
        case .questions:
            let category = Baseline.practiceCategories.first { t.contains($0.rawValue.lowercased()) }
                ?? .productSense
            guard !exists(PrepSession.self, on: day, in: context, where: { $0.category == category }) else { return }
            context.insert(PrepSession(date: day, category: category, durationMinutes: minutes))

        case .pages:
            // Prep reading is a PrepSession in the .reading category. The
            // reading HABIT is deliberately not written here: ReadingLog is
            // book-linked and belongs to the library, and inventing a book to
            // satisfy it would put a phantom row in your shelf. The session
            // itself is the evidence — DayEvidence reads sessions directly.
            if t.contains("interview prep") {
                guard !exists(PrepSession.self, on: day, in: context, where: { $0.category == .reading }) else { return }
                context.insert(PrepSession(date: day, category: .reading, durationMinutes: minutes))
            }

        case .applications:
            // No count field on this model, and none needed: it records THAT
            // you applied. The session keeps how many.
            guard !exists(JobApplication.self, on: day, in: context, where: { _ in true }) else { return }
            context.insert(JobApplication(date: day, appliedToday: true))

        case .frames:
            guard !exists(LeisureLog.self, on: day, in: context, where: { $0.activity == .photography }) else { return }
            context.insert(LeisureLog(date: day, activity: .photography, durationMinutes: minutes))

        case .articles:
            // Product reading for the interview: a PrepSession in the reading
            // category, same as prep-reading measured in pages.
            guard !exists(PrepSession.self, on: day, in: context, where: { $0.category == .reading }) else { return }
            context.insert(PrepSession(date: day, category: .reading, durationMinutes: minutes))

        case .none:
            return
        }
        context.saveOrLog("activity.evidence")
    }

    /// One evidence row per kind per day — logging the same block twice must
    /// not double-count it into the neglect ranking.
    private static func exists<T: PersistentModel>(_ type: T.Type, on day: Date,
                                                   in context: ModelContext,
                                                   where matches: (T) -> Bool) -> Bool {
        let cal = Calendar.current
        let rows = (try? context.fetch(FetchDescriptor<T>())) ?? []
        return rows.contains { row in
            guard let rowDay = (row as? any DatedRecord)?.recordDate else { return false }
            return cal.isDate(rowDay, inSameDayAs: day) && matches(row)
        }
    }
}

/// Lets the dedup check above read a date off any evidence row without a
/// switch that has to be updated every time a new kind appears.
protocol DatedRecord { var recordDate: Date { get } }
extension PrepSession: DatedRecord { var recordDate: Date { date } }
extension JobApplication: DatedRecord { var recordDate: Date { date } }
extension LeisureLog: DatedRecord { var recordDate: Date { date } }
