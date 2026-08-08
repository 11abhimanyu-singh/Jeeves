//
//  CalendarSync.swift
//  Jeeves
//
//  One button, every ticked calendar, a whole window of days.
//
//  Importing already existed, but only ONE DAY AT A TIME and only from the
//  planner: open the day, tap import, review, repeat. Ticking Outlook and Google
//  in Settings did nothing by itself, so "I've connected my calendars" and "my
//  calendar is in Jeeves" were different states with nothing in between.
//
//  The merge rules here are the ones the per-day path already used, moved
//  somewhere both can call:
//    • a tombstoned event stays deleted — re-syncing must not resurrect it;
//    • an event we already hold is UPDATED by external id, never duplicated,
//      because the same event synced from three days of its span once produced
//      a trip called "Bali + Bali + Bali";
//    • anything else is inserted.
//

import Foundation
import SwiftData

enum CalendarSync {

    /// What one sync actually did. Counted rather than described, so the button
    /// can say "4 added, 1 updated" instead of "Synced!" — a receipt you can
    /// check against the day, which is the whole house style.
    struct Result: Equatable {
        var added = 0
        var updated = 0
        var skipped = 0        // tombstoned, or already identical
        var isEmpty: Bool { added == 0 && updated == 0 }

        var summary: String {
            if isEmpty {
                return skipped > 0
                    ? "Everything already matches — nothing to bring over."
                    : "Nothing in those calendars for the next few weeks."
            }
            var parts: [String] = []
            if added > 0 { parts.append("\(added) added") }
            if updated > 0 { parts.append("\(updated) updated") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// How far ahead one tap reaches. Long enough to pull a trip that is a few
    /// weeks out, short enough that the review stays comprehensible.
    static let windowDays = 30

    /// Merge `found` into the store. Pure of EventKit so the rules can be tested
    /// without a device calendar — the fetch is the caller's job.
    @discardableResult
    static func merge(_ found: [CalendarEvent], into context: ModelContext,
                      existing: [DailyEvent], tombstoned: Set<String>) -> Result {
        var result = Result()

        for c in found {
            if !c.externalID.isEmpty, tombstoned.contains(c.externalID) {
                result.skipped += 1
                continue
            }

            if !c.externalID.isEmpty,
               let held = existing.first(where: { $0.externalID == c.externalID }) {
                let unchanged = held.title == c.title
                    && held.startMinute == c.startMinute
                    && held.endMinute == c.endMinute
                    && held.isAllDay == c.isAllDay
                    && held.destinationAddress == c.location
                    && held.spanEndDate?.startOfDay == (c.spanDays > 1 ? c.endDay?.startOfDay : nil)
                if unchanged {
                    result.skipped += 1
                    continue
                }
                held.title = c.title
                held.isAllDay = c.isAllDay
                held.startMinute = c.startMinute
                held.endMinute = c.endMinute
                if let s = c.startDay { held.date = s }
                held.spanEndDate = c.spanDays > 1 ? c.endDay : nil
                if !c.location.isEmpty, c.location != held.destinationAddress {
                    held.destinationAddress = c.location
                    held.destinationLat = c.latitude
                    held.destinationLng = c.longitude
                }
                result.updated += 1
                continue
            }

            // No external id to match on — fall back to the same day/title/start
            // triple the per-day importer used, so a calendar without stable ids
            // still cannot produce a second copy of the same meeting.
            let day = c.startDay?.startOfDay
            if existing.contains(where: {
                $0.title == c.title && $0.startMinute == c.startMinute
                    && (day == nil || $0.date.startOfDay == day)
            }) {
                result.skipped += 1
                continue
            }

            let event = DailyEvent(
                date: c.startDay ?? Date().startOfDay, title: c.title,
                startMinute: c.startMinute, endMinute: c.endMinute,
                destinationAddress: c.location, outboundStart: .home, source: .calendar,
                isAllDay: c.isAllDay,
                spanEndDate: c.spanDays > 1 ? c.endDay : nil,
                externalID: c.externalID
            )
            event.destinationLat = c.latitude
            event.destinationLng = c.longitude
            context.insert(event)
            result.added += 1
        }
        return result
    }

    /// The whole thing: ask for access, read every ticked calendar across the
    /// window, merge, save.
    @MainActor
    static func run(context: ModelContext, from start: Date = Date().startOfDay) async -> Result? {
        guard await EventKitService.requestAccess() else { return nil }
        let end = Calendar.current.date(byAdding: .day, value: windowDays, to: start) ?? start
        let found = EventKitService.events(from: start, to: end,
                                           calendarIDs: EventKitService.selectedCalendarIDs)
        let existing = (try? context.fetch(FetchDescriptor<DailyEvent>())) ?? []
        let result = merge(found, into: context,
                           existing: existing, tombstoned: CalendarTombstone.ids(in: context))
        context.saveOrLog("calendar.sync")
        return result
    }
}
