//
//  DailyEvent.swift
//  Jeeves
//
//  A one-off commitment for a given day that acts as a hard scheduling
//  anchor (PRD §5.5). Unlike a SavedLocation, an event carries its own
//  destination address and, per day, the point the user leaves from
//  (Home / Work / Gym). Return is always Event → Home (PRD §5.4), so it
//  isn't stored.
//

import Foundation
import SwiftData

enum EventSource: String, Codable, CaseIterable {
    case manual = "Manual"
    case screenshot = "Screenshot"
    case calendar = "Calendar"
}

@Model
final class DailyEvent {
    var date: Date = Date.distantPast   // startOfDay — which day this event belongs to
    var title: String = ""
    var startMinute: Int = 0        // minutes since midnight
    var endMinute: Int = 0
    var destinationAddress: String = ""
    // Exact pin from a resolved Google Maps link (nil until/unless one is pasted).
    // destinationAddress carries the human-readable place; these carry the precise
    // coordinates for pin-accurate routing and a future map view.
    var destinationLat: Double? = nil
    var destinationLng: Double? = nil
    var outboundStartRaw: String = LocationKind.home.rawValue   // LocationKind.rawValue — where the user leaves from, asked per day
    var sourceRaw: String = EventSource.manual.rawValue
    // An all-day calendar event has no start/end time — it's day-long context the
    // planner works AROUND, never a timed block (startMinute/endMinute are unused).
    var isAllDay: Bool = false
    /// The LAST day this event covers when it spans several (nil = single day).
    /// Google's all-day end is exclusive, so this is already decremented — the
    /// span is what lets one sync set up a whole trip instead of one orphaned
    /// day.
    var spanEndDate: Date? = nil
    /// Google's event id, so a re-sync updates rather than duplicates.
    var externalID: String = ""

    /// How many days this event covers, inclusive.
    var spanDays: Int {
        guard let spanEndDate else { return 1 }
        let d = Calendar.current.dateComponents([.day], from: date.startOfDay,
                                                to: spanEndDate.startOfDay).day ?? 0
        return max(1, d + 1)
    }

    var outboundStart: LocationKind {
        get { LocationKind(rawValue: outboundStartRaw) ?? .home }
        set { outboundStartRaw = newValue.rawValue }
    }

    var source: EventSource {
        get { EventSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    init(
        date: Date,
        title: String,
        startMinute: Int,
        endMinute: Int,
        destinationAddress: String = "",
        outboundStart: LocationKind = .home,
        source: EventSource = .manual,
        isAllDay: Bool = false,
        spanEndDate: Date? = nil,
        externalID: String = ""
    ) {
        self.date = date
        self.title = title
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.destinationAddress = destinationAddress
        self.outboundStartRaw = outboundStart.rawValue
        self.sourceRaw = source.rawValue
        self.isAllDay = isAllDay
        self.spanEndDate = spanEndDate
        self.externalID = externalID
    }
}
