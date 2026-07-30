//
//  AppEvent.swift
//  Jeeves
//
//  An append-only event log. The store keeps FINAL STATES, which is why two
//  workouts stuck "live" were visible but "the workout was started three
//  times during gym hour" was not — behavior vanishes the moment state is
//  overwritten. Every notable action appends here and nothing ever mutates
//  a row, so behavioral anomaly rules (and the daily digest) have a
//  trustworthy sequence to read. Kept deliberately tiny: a timestamp, a
//  kind, one human-readable detail line, and an optional subject UUID.
//

import Foundation
import SwiftData

enum AppEventKind: String, Codable, CaseIterable {
    case workoutStarted        // watch said a session began
    case watchSummaryArrived   // end-of-workout summary landed and matched
    case watchSummaryCreated   // summary arrived with nothing to match — new row
    case workoutSaved          // user saved a workout on the phone
    case planRefusedTravel     // a generator refused a travel-mode day
    case plansSwept            // TravelGuard deleted plans under a trip
    case tripCreated
    case tripExtended          // absorb/repair grew a trip's window
    case journeySaved
    case journeyMeasured
    case nudgeScheduled        // leave-by notification set
    case nudgeCancelled
    case calendarSynced
    case travelCleanup         // user-invoked clean_travel_data ran
    case toolCall              // any chat tool invocation, with input + result digest
}

@Model
final class AppEvent {
    var date: Date = Date.distantPast
    var kindRaw: String = ""
    var detail: String = ""
    var subjectID: String = ""

    var kind: AppEventKind? { AppEventKind(rawValue: kindRaw) }

    init(date: Date = Date(), kind: AppEventKind, detail: String, subjectID: String = "") {
        self.date = date
        self.kindRaw = kind.rawValue
        self.detail = detail
        self.subjectID = subjectID
    }
}

enum EventLog {
    /// Append one event. Saves immediately — an event that only exists in an
    /// unsaved context is an event that never happened when the app dies.
    static func log(_ kind: AppEventKind, _ detail: String,
                    subject: UUID? = nil, context: ModelContext) {
        context.insert(AppEvent(kind: kind, detail: detail,
                                subjectID: subject?.uuidString ?? ""))
        context.saveOrLog("EventLog.\(kind.rawValue)")
    }
}
