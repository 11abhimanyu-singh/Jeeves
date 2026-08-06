//
//  EventKitService.swift
//  Jeeves
//
//  Every calendar on the device, without owning a single OAuth flow.
//
//  The alternative was a Microsoft Graph client: an app registration, PKCE, two
//  sets of refresh tokens, per-account Keychain entries, and sync code to
//  maintain forever — all to reach two Outlook accounts. iOS already holds those
//  accounts, plus Google, plus iCloud, plus whatever gets added next year, and
//  keeps them synced. This reads what the OS already has.
//
//  It deliberately produces the same `CalendarEvent` value the Google path
//  produces, so the import path downstream — idempotent upsert by externalID,
//  trips following their backing event, tombstones — is inherited rather than
//  rewritten.
//
//  ON IDENTITY. `calendarItemExternalIdentifier` is the iCalUID: the SAME string
//  for one meeting in every mailbox it lands in. Using it as the externalID
//  means a meeting invited to both Outlook accounts upserts one row instead of
//  appearing twice — the dedup is a consequence of choosing the right key, not
//  a pass over the data afterwards.
//

import Foundation
import EventKit

enum EventKitService {
    /// One store for the process. EKEventStore is expensive to build and its
    /// change notifications are per-instance.
    static let store = EKEventStore()

    /// A calendar the user can choose to include.
    struct CalendarChoice: Identifiable, Equatable {
        let id: String          // EKCalendar.calendarIdentifier
        let title: String       // "Calendar", "Work", "Birthdays"
        let account: String     // the SOURCE — "Outlook", "iCloud", "Gmail"
        let colorHex: String?
    }

    // MARK: Access

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Full access, not write-only: the whole point is reading what's there.
    /// Returns whether we ended up authorized, so callers don't re-interpret
    /// the several ways this can fail.
    @discardableResult
    static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    // MARK: Calendars

    /// Every readable calendar, grouped-friendly: account first, then title.
    /// Includes calendars from every account on the device — that IS the
    /// multi-account support.
    static func calendars() -> [CalendarChoice] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
            .map { cal in
                CalendarChoice(id: cal.calendarIdentifier,
                               title: cal.title,
                               account: cal.source?.title ?? "Other",
                               colorHex: nil)
            }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    // MARK: Events

    /// Timed and all-day events between two dates, from the chosen calendars.
    ///
    /// `calendarIDs` empty means EVERY calendar — the sensible default before
    /// the user has picked, and what someone with one account expects.
    static func events(from start: Date, to end: Date,
                       calendarIDs: Set<String>) -> [CalendarEvent] {
        guard isAuthorized else { return [] }
        let all = store.calendars(for: .event)
        let chosen = calendarIDs.isEmpty
            ? all
            : all.filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
        // Two accounts holding the same meeting return it twice, with the same
        // external identifier. Keyed by that, the second simply overwrites the
        // first — one row, not two.
        var byIdentity: [String: CalendarEvent] = [:]
        var unidentified: [CalendarEvent] = []
        for ekEvent in store.events(matching: predicate) {
            guard let mapped = calendarEvent(from: ekEvent) else { continue }
            if let key = ekEvent.calendarItemExternalIdentifier, !key.isEmpty {
                byIdentity[key] = mapped
            } else {
                unidentified.append(mapped)
            }
        }
        return (Array(byIdentity.values) + unidentified)
            .sorted { ($0.startDay ?? .distantPast, $0.startMinute) < ($1.startDay ?? .distantPast, $1.startMinute) }
    }

    /// EKEvent → the value type the rest of the app already understands.
    ///
    /// ALL-DAY END DATES DIFFER BY PROVIDER. Google's all-day `end` is
    /// EXCLUSIVE, so its importer subtracts a day. EventKit's `endDate` for an
    /// all-day event is the END of the final day, so the last covered day is
    /// simply its startOfDay — no subtraction. Getting this backwards is a
    /// silent off-by-one that makes every trip a day too long or too short.
    static func calendarEvent(from event: EKEvent) -> CalendarEvent? {
        guard let start = event.startDate else { return nil }
        let end = event.endDate ?? start
        let cal = Calendar.current

        let startDay = cal.startOfDay(for: start)

        // A MEETING THAT CROSSES MIDNIGHT IS STILL ONE MEETING.
        //
        // A 22:30–00:00 webinar occupies two calendar dates, and taking the
        // span from those dates made it "2 days with a location" — which is
        // precisely the shape TravelDetection reads as a trip. It offered to
        // put the day into travel mode for an online talk.
        //
        // So a TIMED event spans multiple days only when it genuinely runs
        // longer than a day; anything shorter belongs to the day it started.
        // All-day events keep date arithmetic, because that is what a real
        // multi-day trip looks like.
        let spansRealDays = end.timeIntervalSince(start) > 24 * 60 * 60
        let endDay = (event.isAllDay || spansRealDays) ? cal.startOfDay(for: end) : startDay

        // …and its end minute is 24:00, not 00:00. Midnight read as minute 0
        // put the end BEFORE the start, which is a negative-length block to
        // everything downstream.
        let rawEnd = minuteOfDay(end, cal)
        let endMinute = (!event.isAllDay && endDay == startDay && rawEnd <= minuteOfDay(start, cal))
            ? 24 * 60
            : rawEnd

        var mapped = CalendarEvent(
            title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            startMinute: event.isAllDay ? 0 : minuteOfDay(start, cal),
            endMinute: event.isAllDay ? 0 : endMinute,
            location: locationText(event),
            isAllDay: event.isAllDay,
            externalID: event.calendarItemExternalIdentifier.map { "ek:\($0)" } ?? "",
            startDay: startDay,
            endDay: endDay
        )
        guard !mapped.title.isEmpty else { return nil }
        // The pin, when the calendar carries one. This is the quiet win: the
        // app otherwise geocodes a venue NAME to find coordinates, and a name
        // it can't resolve is how a 265 km drive once got planned as a 30-min
        // commute. A structured location arrives already located.
        if let geo = event.structuredLocation?.geoLocation {
            mapped.latitude = geo.coordinate.latitude
            mapped.longitude = geo.coordinate.longitude
        }
        return mapped
    }

    /// The address if there is one, else the structured location's title —
    /// "Tasvaa Skin And Hair Clinic" is more use than an empty string.
    ///
    /// A JOINING LINK IS NOT A PLACE. Calendar invites routinely put
    /// "https://maven.com/s/joinlive/…" or a Teams URL in the location field.
    /// Stored as an address it becomes somewhere to commute to, and combined
    /// with a span it reads as travel — the app offered a trip for a webinar.
    /// A Maps link is the exception: that one really does name a place, and
    /// the app already knows how to resolve it.
    static func locationText(_ event: EKEvent) -> String {
        let raw = (event.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = (event.structuredLocation?.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in [raw, fallback] where !candidate.isEmpty {
            if isOnlineMeetingLink(candidate) { continue }
            return candidate
        }
        return ""
    }

    /// A web link that isn't a Maps link — i.e. somewhere you attend, not
    /// somewhere you travel to.
    static func isOnlineMeetingLink(_ text: String) -> Bool {
        let t = text.lowercased()
        guard t.hasPrefix("http://") || t.hasPrefix("https://") else { return false }
        return !GoogleMapsService.isMapsLink(text)
    }

    private static func minuteOfDay(_ date: Date, _ cal: Calendar) -> Int {
        cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
    }

    // MARK: Which calendars count

    /// Chosen calendar identifiers. Empty = all of them, which is both the
    /// pre-choice default and the right answer for a single-account device.
    ///
    /// UserDefaults for the same reason DayPreferences uses it: read from
    /// non-view code where no ModelContext is in scope, and worth nothing to
    /// sync — calendar identifiers are per-device.
    static let selectedKey = "eventKit.selectedCalendarIDs"

    static var selectedCalendarIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: selectedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: selectedKey) }
    }

    /// Has the user connected device calendars at all? Distinct from "which
    /// ones" — an empty selection with access granted means every calendar.
    static let enabledKey = "eventKit.enabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}
