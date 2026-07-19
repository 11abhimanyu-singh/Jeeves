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
    var date: Date              // startOfDay — which day this event belongs to
    var title: String
    var startMinute: Int        // minutes since midnight
    var endMinute: Int
    var destinationAddress: String
    var outboundStartRaw: String   // LocationKind.rawValue — where the user leaves from, asked per day
    var sourceRaw: String

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
        source: EventSource = .manual
    ) {
        self.date = date
        self.title = title
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.destinationAddress = destinationAddress
        self.outboundStartRaw = outboundStart.rawValue
        self.sourceRaw = source.rawValue
    }
}
