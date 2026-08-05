//
//  DataRepair.swift
//  Jeeves
//
//  A one-shot, user-invoked pass over historical data that the daily digest
//  keeps reporting. Fixing the CODE that produced a bad row does not clean the
//  row — every morning the digest re-reports the same fossils, and real new
//  findings get lost in the noise.
//
//  The standing rule still holds: nothing here runs automatically. The user
//  opens it, reads exactly what will change, and confirms. Anything requiring
//  a judgement only they can make (which of three books is the real one, which
//  of two merged trips they meant) is REPORTED, never guessed — those findings
//  carry the sentence to say in chat instead of a fix button.
//

import Foundation
import SwiftData

enum DataRepair {

    /// One thing wrong with the stored data.
    struct Finding: Identifiable {
        enum Action { case fixable, manual }
        let id = UUID()
        let title: String
        let detail: String
        let action: Action
        /// What the user should say in chat, for the ones only they can settle.
        var chatHint: String? = nil
        /// Applied when the user confirms; returns a receipt line.
        var fix: (() -> String)? = nil
    }

    // MARK: Scan

    @MainActor
    static func scan(context: ModelContext) -> [Finding] {
        var findings: [Finding] = []
        findings += duplicateTrips(context)
        findings += mergedTitles(context)
        findings += containedStays(context)
        findings += duplicateJourneys(context)
        findings += redundantSpanRows(context)
        findings += staysWrittenWithTheOldDepartMeaning(context)
        findings += staleCardio(context)
        findings += planClockAndBlocks(context)
        findings += bookIssues(context)
        return findings
    }

    /// Applies every fixable finding, in order, and returns the receipts.
    /// Each repair is logged so the digest reports what was cleaned rather
    /// than the cleanup hiding the anomaly it came from.
    @MainActor
    static func applyAll(_ findings: [Finding], context: ModelContext) -> [String] {
        var receipts: [String] = []
        for finding in findings where finding.action == .fixable {
            guard let fix = finding.fix else { continue }
            let receipt = fix()
            receipts.append(receipt)
            EventLog.log(.travelCleanup, "data repair: \(receipt)", context: context)
        }
        context.saveOrLog("dataRepair.applyAll")
        return receipts
    }

    // MARK: Trips

    @MainActor
    private static func duplicateTrips(_ context: ModelContext) -> [Finding] {
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        var groups: [String: [Trip]] = [:]
        for t in trips {
            let key = "\(t.title.lowercased())|\(t.startDate.timeIntervalSince1970)|\(t.endDate.timeIntervalSince1970)"
            groups[key, default: []].append(t)
        }
        return groups.values.filter { $0.count > 1 }.map { group in
            // Deterministic keeper: the lowest id, so two devices agree.
            let sorted = group.sorted { $0.id.uuidString < $1.id.uuidString }
            let keeper = sorted[0]
            let losers = Array(sorted.dropFirst())
            return Finding(
                title: "\(group.count) identical '\(keeper.title)' trips",
                detail: "Same title, same dates (\(TravelGuard.dayRange(keeper))). Keeping one and moving anything attached to it.",
                action: .fixable,
                fix: {
                    let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
                    let segs = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
                    var moved = 0
                    for loser in losers {
                        for s in stays where s.tripID == loser.id { s.tripID = keeper.id; moved += 1 }
                        for g in segs where g.tripID == loser.id { g.tripID = keeper.id; moved += 1 }
                        context.delete(loser)
                    }
                    return "collapsed \(losers.count) duplicate '\(keeper.title)' trip(s), moved \(moved) attached row(s)"
                })
        }
    }

    /// Legacy cleanup joined merged trips with " + ". When both halves are the
    /// same name that's just a mangled title and safe to repair. When they
    /// differ, two real trips were welded together — only the user knows which
    /// they meant, so that one is reported.
    @MainActor
    private static func mergedTitles(_ context: ModelContext) -> [Finding] {
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        return trips.compactMap { trip -> Finding? in
            guard trip.title.contains(" + ") else { return nil }
            let halves = trip.title.components(separatedBy: " + ")
            let normalized = Set(halves.map {
                $0.lowercased().replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
            })
            if normalized.count == 1, let clean = halves.first {
                return Finding(
                    title: "Trip name doubled: '\(trip.title)'",
                    detail: "The same name joined to itself by an old merge. Renaming it '\(clean)'.",
                    action: .fixable,
                    fix: { let old = trip.title; trip.title = clean
                           return "renamed '\(old)' → '\(clean)'" })
            }
            return Finding(
                title: "Two trips welded into one: '\(trip.title)'",
                detail: "An old merge joined different trips (\(TravelGuard.dayRange(trip))). Splitting them needs your call — I won't guess which days belong to which.",
                action: .manual,
                chatHint: "In chat: \"delete the trip on \(shortDay(trip.startDate))\" then re-add the one you actually want.")
        }
    }

    // MARK: Stays

    @MainActor
    private static func containedStays(_ context: ModelContext) -> [Finding] {
        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        var redundant: [TripStay] = []
        for s in stays {
            let container = stays.first {
                $0.id != s.id && $0.tripID == s.tripID
                    && $0.place.lowercased() == s.place.lowercased()
                    && $0.arriveDate <= s.arriveDate && s.departDate <= $0.departDate
                    && ($0.departDate.timeIntervalSince($0.arriveDate)
                        > s.departDate.timeIntervalSince(s.arriveDate))
            }
            if container != nil { redundant.append(s) }
        }
        guard !redundant.isEmpty else { return [] }
        let names = Set(redundant.map(\.place)).sorted().joined(separator: ", ")
        return [Finding(
            title: "\(redundant.count) stay(s) sitting inside a longer stay",
            detail: "Same hotel, same trip, dates already covered by a longer booking (\(names)). Removing the short ones.",
            action: .fixable,
            fix: {
                for s in redundant { context.delete(s) }
                return "removed \(redundant.count) redundant stay(s): \(names)"
            })]
    }

    // MARK: Journeys

    @MainActor
    private static func duplicateJourneys(_ context: ModelContext) -> [Finding] {
        let segs = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
        var groups: [String: [TravelSegment]] = [:]
        for s in segs {
            let day = Calendar.current.startOfDay(for: s.day)
            let key = "\(s.tripID.uuidString)|\(s.modeRaw)|\(s.label.lowercased())|\(day.timeIntervalSince1970)"
            groups[key, default: []].append(s)
        }
        return groups.values.filter { $0.count > 1 }.map { group in
            // Keep the MEASURED one — a 0-minute twin is the unmeasured copy.
            let sorted = group.sorted {
                ($0.travelMinutes, $0.id.uuidString) > ($1.travelMinutes, $1.id.uuidString)
            }
            let keeper = sorted[0]
            let losers = Array(sorted.dropFirst())
            let name = keeper.label.isEmpty ? keeper.mode.label : keeper.label
            return Finding(
                title: "\(group.count) copies of '\(name)'",
                detail: "Same trip, same day, same leg. Keeping the measured one (\(keeper.travelMinutes) min) and cancelling the others' reminders.",
                action: .fixable,
                fix: {
                    for l in losers { TravelNotifier.cancel(segment: l); context.delete(l) }
                    return "collapsed \(losers.count) duplicate '\(name)' journey(s), kept the \(keeper.travelMinutes)-min measurement"
                })
        }
    }

    // MARK: Events

    /// A synced multi-day event stores ONE row carrying spanEndDate. Older
    /// syncs also wrote a row per day, so anything expanding the span
    /// inclusively counts those days twice.
    @MainActor
    private static func redundantSpanRows(_ context: ModelContext) -> [Finding] {
        let events = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        let spans = events.filter { $0.spanEndDate != nil }
        var redundant: [DailyEvent] = []
        for span in spans {
            guard let end = span.spanEndDate else { continue }
            for e in events where e.id != span.id
                && e.title == span.title
                && e.spanEndDate == nil
                && e.date > span.date && e.date <= end {
                redundant.append(e)
            }
        }
        guard !redundant.isEmpty else { return [] }
        let titles = Set(redundant.map(\.title)).sorted().joined(separator: ", ")
        return [Finding(
            title: "\(redundant.count) duplicate day-row(s) inside a multi-day event",
            detail: "'\(titles)' is stored once as a span AND again as separate day rows, so those days read as double-booked. Removing the extra rows.",
            action: .fixable,
            fix: {
                for e in redundant {
                    if !e.externalID.isEmpty {
                        context.insert(CalendarTombstone(externalID: e.externalID))
                    }
                    context.delete(e)
                }
                return "removed \(redundant.count) duplicate day-row(s) for \(titles)"
            })]
    }

    // MARK: Check-ins

    @MainActor
    /// Stays saved before `departDate` had one meaning.
    ///
    /// The calendar importer used to write the last NIGHT there; the ticket
    /// importer wrote the day you FLY OUT. Both landed in the same field, so a
    /// nights count was wrong for one of them whichever way you read it. New
    /// rows are written as last-day-present, and these are the old ones — a
    /// real store had a stay whose arrive and depart are the same day, which
    /// now reads as nought nights.
    ///
    /// The discriminator only exists on a trip with more than one stay: if a
    /// stay's departDate is the day BEFORE the next stay's arriveDate, it was
    /// written the old way and is one day short. If they are equal it is
    /// already last-day-present. A lone stay cannot be told apart at all, so it
    /// is marked unsettled rather than guessed at — the count then renders as a
    /// pair, which is the true state of the knowledge.
    private static func staysWrittenWithTheOldDepartMeaning(_ context: ModelContext) -> [Finding] {
        let stays = (try? context.fetch(FetchDescriptor<TripStay>())) ?? []
        guard !stays.isEmpty else { return [] }
        let cal = Calendar.current
        var short: [TripStay] = []
        var lone: [TripStay] = []

        // ONLY the calendar importer ever wrote the old meaning. A ticket-built
        // stay's end is proved by a flight (SQ 510 leaves Singapore at 20:05 on
        // the 14th) and a chat-built one was stated by the user; both carry an
        // empty externalID, and both were being flagged as "an end nobody can
        // settle" and then marked unsettled for ever. Repairing a row that was
        // right is worse than leaving one that was wrong.
        func couldBeOldCalendarRow(_ s: TripStay) -> Bool {
            !s.externalID.isEmpty && !s.endIsUnsettled
        }
        // A flight that departs on the stay's own departDate proves the ticket
        // meaning is already in force — never move that end.
        let segments = (try? context.fetch(FetchDescriptor<TravelSegment>())) ?? []
        func aFlightLeavesOn(_ s: TripStay) -> Bool {
            segments.contains {
                $0.tripID == s.tripID && $0.mode == .flight
                    && $0.departAt != .distantPast
                    && cal.isDate($0.departAt, inSameDayAs: s.departDate)
            }
        }

        for (_, group) in Dictionary(grouping: stays, by: \.tripID) {
            let ordered = group.sorted { $0.arriveDate < $1.arriveDate }
            guard ordered.count > 1 else {
                if let only = ordered.first, couldBeOldCalendarRow(only), !aFlightLeavesOn(only) {
                    lone.append(only)
                }
                continue
            }
            for (a, b) in zip(ordered, ordered.dropFirst()) {
                guard couldBeOldCalendarRow(a), !aFlightLeavesOn(a) else { continue }
                let dayAfterA = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: a.departDate))
                // Adjacency alone is not proof: a genuine gap day between two
                // stays, and an overnight flight landing the next morning, both
                // look like this. Require the pair to be CONTIGUOUS in the way
                // only the old convention produced — a's end one day before b's
                // start, with no journey of a's own departing that day.
                if let dayAfterA, cal.isDate(dayAfterA, inSameDayAs: b.arriveDate) {
                    short.append(a)          // old meaning: one day short
                }
            }
            if let last = ordered.last, couldBeOldCalendarRow(last), !aFlightLeavesOn(last) {
                lone.append(last)
            }
        }

        guard !short.isEmpty || !lone.isEmpty else { return [] }
        var findings: [Finding] = []

        if !short.isEmpty {
            let names = short.map(\.place).joined(separator: ", ")
            findings.append(Finding(
                title: "\(short.count) stay\(short.count == 1 ? "" : "s") end a day early",
                detail: "\(names) — saved when a stay's end meant its last night rather than the day you leave, so each is one night short. The stay that follows proves the right value.",
                action: .fixable,
                fix: {
                    for s in short {
                        s.departDate = (cal.date(byAdding: .day, value: 1, to: s.departDate) ?? s.departDate).startOfDay
                        // The follower that proved the new value also settles
                        // it — leaving the flag alone left "15 or 16 nights"
                        // standing over a date the repair had just settled.
                        s.endIsUnsettled = false
                    }
                    context.saveOrLog("DataRepair.staysWrittenWithTheOldDepartMeaning")
                    return "Moved \(short.count) stay end\(short.count == 1 ? "" : "s") forward a day: \(names)."
                }))
        }
        if !lone.isEmpty {
            let names = lone.map(\.place).joined(separator: ", ")
            findings.append(Finding(
                title: "\(lone.count) stay\(lone.count == 1 ? "" : "s") with an end nobody can settle",
                detail: "\(names) — nothing follows these, so I can't tell whether the last date is a night there or the day you leave. I'll show both readings rather than pick one.",
                action: .fixable,
                fix: {
                    for s in lone { s.endIsUnsettled = true }
                    context.saveOrLog("DataRepair.markUnsettledStayEnds")
                    return "Marked \(lone.count) stay end\(lone.count == 1 ? "" : "s") as unsettled: \(names)."
                }))
        }
        return findings
    }

    private static func staleCardio(_ context: ModelContext) -> [Finding] {
        let checkins = (try? context.fetch(FetchDescriptor<CheckIn>())) ?? []
        let stale = checkins.filter {
            !$0.cardio && ($0.cardioType != nil || $0.cardioDuration != nil || $0.cardioIncline != nil)
        }
        guard !stale.isEmpty else { return [] }
        let days = stale.map { shortDay($0.date) }.joined(separator: ", ")
        return [Finding(
            title: "\(stale.count) check-in(s) with leftover cardio details",
            detail: "Marked as no cardio but still carrying a type or duration (\(days)). Clearing the leftovers.",
            action: .fixable,
            fix: {
                for c in stale { c.cardioType = nil; c.cardioDuration = nil; c.cardioIncline = nil }
                return "cleared stale cardio details on \(stale.count) check-in(s): \(days)"
            })]
    }

    // MARK: Plans

    /// Two shapes the audit fails on: a clock past midnight written as "31:00",
    /// and a block that starts and ends at the same minute.
    @MainActor
    private static func planClockAndBlocks(_ context: ModelContext) -> [Finding] {
        let plans = (try? context.fetch(FetchDescriptor<DailyPlanState>())) ?? []
        var broken: [(DailyPlanState, GeneratedPlan, Int, Int)] = []   // plan, decoded, badClocks, zeroBlocks
        for state in plans {
            guard let json = state.generatedPlanJSON,
                  let data = json.data(using: .utf8),
                  let plan = try? JSONDecoder().decode(GeneratedPlan.self, from: data) else { continue }
            let badClocks = plan.blocks.filter { overflowed($0.endTime) || overflowed($0.startTime) }.count
            let zeroBlocks = plan.blocks.filter {
                guard let s = $0.startMinute, let e = $0.endMinute else { return false }
                return s == e
            }.count
            if badClocks > 0 || zeroBlocks > 0 { broken.append((state, plan, badClocks, zeroBlocks)) }
        }
        guard !broken.isEmpty else { return [] }
        let days = broken.map { shortDay($0.0.date) }.joined(separator: ", ")
        let clocks = broken.reduce(0) { $0 + $1.2 }
        let zeros = broken.reduce(0) { $0 + $1.3 }
        var parts: [String] = []
        if clocks > 0 { parts.append("\(clocks) time(s) past midnight written as 25:00+") }
        if zeros > 0 { parts.append("\(zeros) block(s) with no length") }
        return [Finding(
            title: "\(broken.count) stored plan(s) with unreadable times",
            detail: "\(parts.joined(separator: " and ")) on \(days). Any strict clock parser breaks on these.",
            action: .fixable,
            fix: {
                var fixedClocks = 0, droppedBlocks = 0
                for (state, plan, _, _) in broken {
                    var blocks: [GeneratedBlock] = []
                    for b in plan.blocks {
                        var start = b.startTime, end = b.endTime
                        if overflowed(start) { start = clamp(start); fixedClocks += 1 }
                        if overflowed(end) { end = clamp(end); fixedClocks += 1 }
                        let s = GeneratedBlock.minutes(from: start)
                        let e = GeneratedBlock.minutes(from: end)
                        if let s, let e, s == e { droppedBlocks += 1; continue }
                        blocks.append(GeneratedBlock(title: b.title, startTime: start, endTime: end,
                                                     note: b.note, isAnchor: b.isAnchor, kind: b.kind))
                    }
                    let repaired = GeneratedPlan(blocks: blocks, dropped: plan.dropped,
                                                 shrunk: plan.shrunk, summary: plan.summary,
                                                 boundaryTime: plan.boundaryTime)
                    if let encoded = try? JSONEncoder().encode(repaired),
                       let text = String(data: encoded, encoding: .utf8) {
                        state.generatedPlanJSON = text
                    }
                }
                return "repaired \(fixedClocks) clock value(s) and dropped \(droppedBlocks) zero-length block(s) across \(broken.count) plan(s)"
            })]
    }

    /// "31:00" — past the end of the day. 24:00 is the day's edge.
    private static func overflowed(_ hhmm: String) -> Bool {
        guard let m = GeneratedBlock.minutes(from: hhmm) else {
            // Not parseable as HH:MM at all — an hour over 23 fails the parser.
            let hour = Int(hhmm.split(separator: ":").first ?? "") ?? 0
            return hour > 23
        }
        return m > 24 * 60
    }

    private static func clamp(_ hhmm: String) -> String { "24:00" }

    // MARK: Books

    @MainActor
    private static func bookIssues(_ context: ModelContext) -> [Finding] {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        var findings: [Finding] = []

        let unflagged = books.filter { $0.isFiction == nil }
        if !unflagged.isEmpty {
            let titles = unflagged.map(\.title).joined(separator: ", ")
            findings.append(Finding(
                title: "\(unflagged.count) book(s) with no fiction/non-fiction flag",
                detail: "The audit fails on a missing flag (\(titles)). Setting them non-fiction — change it in the Library if that's wrong.",
                action: .fixable,
                fix: {
                    for b in unflagged { b.isFiction = false }
                    return "flagged \(unflagged.count) book(s) as non-fiction: \(titles)"
                }))
        }

        var byISBN: [String: [Book]] = [:]
        for b in books where !(b.isbn ?? "").isEmpty { byISBN[b.isbn!, default: []].append(b) }
        for (isbn, group) in byISBN where group.count > 1 {
            let titles = group.map(\.title).joined(separator: " / ")
            findings.append(Finding(
                title: "\(group.count) books share one ISBN",
                detail: "\(isbn) is on: \(titles). They disagree on title and ownership, so which one is real is your call.",
                action: .manual,
                chatHint: "Open Library and delete the ones you don't own — they're the same book under different titles."))
        }
        return findings
    }

    // MARK: Helpers

    private static func shortDay(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return f.string(from: date)
    }
}
