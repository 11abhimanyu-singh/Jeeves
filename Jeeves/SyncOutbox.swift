//
//  SyncOutbox.swift
//  Jeeves
//
//  One consolidated, hands-free export of the app's state to the iCloud Drive
//  "Jeeves" folder, so Claude can read a coherent snapshot from a Mac OR an
//  iCloud-for-Windows PC without tethering the phone. Writes three things
//  together on every trigger:
//
//    heartbeat.json      — read FIRST. device, app version/build, schemaVersion,
//                          writtenAt (IST + raw epoch), row counts, last plan.
//                          Lets the reader tell "device not syncing" from a real
//                          app bug before diagnosing anything.
//    state-latest.json   — a stable, versioned, migration-proof snapshot of the
//                          domain models (the PRIMARY read surface — unlike the
//                          raw SQLite in DataBackup, this never breaks on a
//                          SwiftData schema migration and is trivial to parse on
//                          Windows). Additive: new features add a section.
//    jeeves-diagnostics.json — plan-generation logs (via DiagnosticsSync).
//
//  DataBackup's raw SQLite copy is retained as a full-fidelity fallback and is
//  refreshed only on the infrequent, has-time triggers (launch), not on every
//  plan generation.
//
//  Resilient: if iCloud Documents isn't available the ubiquity URL is nil and
//  this simply does nothing — never a crash. All writes are off the main thread,
//  file-coordinated, and atomic. NEVER contains secrets/tokens/Keychain values.
//

import Foundation
import SwiftData

enum SyncOutbox {
    /// Bump when the export shape changes so the reader can adapt.
    static let schemaVersion = 1

    // MARK: Sendable row snapshots (plain structs so they can cross to a
    // detached writer without touching non-Sendable SwiftData models).

    nonisolated struct PlanRow: Codable, Sendable {
        var date: Date
        var hasGymToday: Bool
        var gymMinute: Int?
        var planConfirmed: Bool
        var isOffline: Bool
        var adherenceScore: Double?
        var adherenceAssessed: Int
        var planJSON: String?
        var manualOutcomesJSON: String?
    }
    nonisolated struct EventRow: Codable, Sendable {
        var date: Date
        var title: String
        var startMinute: Int
        var endMinute: Int
        var destinationAddress: String
        var destinationLat: Double?
        var destinationLng: Double?
        var outboundStart: String
        var source: String
        var isAllDay: Bool
    }
    nonisolated struct CheckInRow: Codable, Sendable {
        var date: Date
        var workedOut: Bool
        var weightTraining: Bool
        var stretching: Bool
        var mobility: Bool
        var cardio: Bool
        var cardioType: String?
        var cardioDuration: Double?
        var cardioIncline: Double?
    }
    nonisolated struct LeisureRow: Codable, Sendable {
        var date: Date
        var activity: String
        var durationMinutes: Double
    }
    nonisolated struct RoutineRow: Codable, Sendable {
        var name: String
        var durationMinutes: Int
        var tier: String
        var note: String?
        var enabled: Bool
        var sortOrder: Int
    }

    nonisolated struct LiftSetRow: Codable, Sendable {
        var order: Int
        var reps: Int
        var weightKg: Double
        var inputType: String
        var holdSeconds: Int
        var addedKg: Double
        var bodyweightKg: Double
    }
    nonisolated struct LiftRow: Codable, Sendable {
        var date: Date
        var exerciseName: String
        var tonnage: Double
        var sets: [LiftSetRow]
    }
    nonisolated struct RunRow: Codable, Sendable {
        var date: Date
        var weekIndex: Int
        var dayIndex: Int
        var durationSec: Int
        var distanceKm: Double
        var avgHeartRate: Int?
        var rpe: Int
    }
    nonisolated struct StretchRow: Codable, Sendable {
        var date: Date
        var routineName: String
        var durationSec: Int
    }
    nonisolated struct ReminderRow: Codable, Sendable {
        var title: String
        var fireAt: Date
        var recurrence: String
        var enabled: Bool
        var completed: Bool
    }
    nonisolated struct TodoRow: Codable, Sendable {
        var title: String
        var priority: String
        var dueDate: Date?
        var done: Bool
    }
    nonisolated struct WorkoutRow: Codable, Sendable {
        var date: Date
        var type: String
        var state: String
        var source: String
        var title: String
        var durationMin: Int
        var avgBPM: Int
        var distanceKm: Double
        var inclinePercent: Double
    }
    /// Most recent chat turns carried in the export (the eval corpus); older
    /// ones stay in the store but don't re-encode on every plan generation.
    static let chatTurnExportLimit = 500

    nonisolated struct ChatTurnRow: Codable, Sendable {
        var timestamp: Date
        var role: String
        var content: String
        var isPlan: Bool          // true when the turn rendered a plan card
    }
    nonisolated struct VoiceNoteRow: Codable, Sendable {
        var date: Date
        var durationSec: Double
        var locale: String
        var transcript: String
        var audioFile: String     // "" once the audio aged out of retention
    }

    nonisolated struct StateSnapshot: Codable, Sendable {
        var schemaVersion: Int
        var exportedAt: Date
        var appVersion: String
        var buildNumber: String
        var device: String
        var plans: [PlanRow]
        var events: [EventRow]
        var checkIns: [CheckInRow]
        var leisure: [LeisureRow]
        var routine: [RoutineRow]
        var lifts: [LiftRow]
        var runs: [RunRow]
        var stretchSessions: [StretchRow]
        var reminders: [ReminderRow]
        var todos: [TodoRow]
        var workouts: [WorkoutRow]
        var chatTurns: [ChatTurnRow]
        var voiceNotes: [VoiceNoteRow]
    }

    nonisolated struct Heartbeat: Codable, Sendable {
        var schemaVersion: Int
        var writtenAt: Date          // rendered IST by the shared encoder
        var writtenAtEpoch: Double   // raw seconds — timezone-proof staleness math
        var appVersion: String
        var buildNumber: String
        var device: String
        var counts: [String: Int]
        var lastPlanAt: Date?
        var lastPlanTrigger: String?
        var lastPlanOutcome: String?
    }

    // MARK: Environment (safe to read from any thread)

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    /// Hardware identifier (e.g. "iPhone16,2"). Uses `uname` so it needs no
    /// main-actor UIDevice access — safe from the background auto-plan task.
    static var deviceModel: String {
        var s = utsname()
        uname(&s)
        let bytes = withUnsafeBytes(of: &s.machine) { Array($0) }   // [UInt8]
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: Export

    /// Snapshot the store to iCloud. Fetches on the caller's `context` thread,
    /// maps to Sendable structs, then writes off the main thread.
    /// - includeRawBackup: also refresh the heavy raw-SQLite copy. Pass `true`
    ///   only on infrequent triggers that have time (app launch); `false` on
    ///   every-plan-generation so bursts don't thrash iCloud.
    static func exportAll(context: ModelContext, includeRawBackup: Bool, now: Date = Date()) {
        let plans   = (try? context.fetch(FetchDescriptor<DailyPlanState>()))   ?? []
        let events  = (try? context.fetch(FetchDescriptor<DailyEvent>()))       ?? []
        let checkIns = (try? context.fetch(FetchDescriptor<CheckIn>()))         ?? []
        let leisure = (try? context.fetch(FetchDescriptor<LeisureLog>()))       ?? []
        let routine = (try? context.fetch(FetchDescriptor<RoutineActivity>()))  ?? []
        let logs    = (try? context.fetch(FetchDescriptor<PlanGenerationLog>())) ?? []
        let liftSessions = (try? context.fetch(FetchDescriptor<LiftSession>())) ?? []
        let liftSets     = (try? context.fetch(FetchDescriptor<LiftSet>()))     ?? []
        let runSessions  = (try? context.fetch(FetchDescriptor<RunSession>()))  ?? []
        let stretches    = (try? context.fetch(FetchDescriptor<StretchLog>()))  ?? []
        let reminders    = (try? context.fetch(FetchDescriptor<Reminder>()))    ?? []
        let todos        = (try? context.fetch(FetchDescriptor<Todo>()))        ?? []
        let allWorkouts  = (try? context.fetch(FetchDescriptor<Workout>()))     ?? []
        let chatTurns    = (try? context.fetch(FetchDescriptor<ChatTurn>()))    ?? []
        let voiceNotes   = (try? context.fetch(FetchDescriptor<VoiceNote>()))   ?? []

        let snapshot = StateSnapshot(
            schemaVersion: schemaVersion, exportedAt: now,
            appVersion: appVersion, buildNumber: buildNumber, device: deviceModel,
            plans: plans.map {
                PlanRow(date: $0.date, hasGymToday: $0.hasGymToday, gymMinute: $0.gymMinute,
                        planConfirmed: $0.planConfirmed, isOffline: $0.generatedPlanIsOffline,
                        adherenceScore: $0.adherenceScore, adherenceAssessed: $0.adherenceAssessed,
                        planJSON: $0.generatedPlanJSON, manualOutcomesJSON: $0.manualOutcomesJSON)
            },
            events: events.map {
                EventRow(date: $0.date, title: $0.title, startMinute: $0.startMinute,
                         endMinute: $0.endMinute, destinationAddress: $0.destinationAddress,
                         destinationLat: $0.destinationLat, destinationLng: $0.destinationLng,
                         outboundStart: $0.outboundStartRaw, source: $0.sourceRaw, isAllDay: $0.isAllDay)
            },
            checkIns: checkIns.map {
                CheckInRow(date: $0.date, workedOut: $0.workedOut, weightTraining: $0.weightTraining,
                           stretching: $0.stretching, mobility: $0.mobility, cardio: $0.cardio,
                           cardioType: $0.cardioType, cardioDuration: $0.cardioDuration,
                           cardioIncline: $0.cardioIncline)
            },
            leisure: leisure.map {
                LeisureRow(date: $0.date, activity: $0.activityRaw, durationMinutes: $0.durationMinutes)
            },
            routine: routine.map {
                RoutineRow(name: $0.name, durationMinutes: $0.durationMinutes, tier: $0.tierRaw,
                           note: $0.note, enabled: $0.enabled, sortOrder: $0.sortOrder)
            },
            lifts: liftSessions.map { s in
                let sets = liftSets.filter { $0.sessionID == s.id }.sorted { $0.order < $1.order }
                return LiftRow(date: s.date, exerciseName: s.exerciseName,
                               tonnage: LiftMath.sessionTonnage(sets),
                               sets: sets.map {
                                   LiftSetRow(order: $0.order, reps: $0.reps, weightKg: $0.weightKg,
                                              inputType: $0.inputTypeRaw, holdSeconds: $0.holdSeconds,
                                              addedKg: $0.addedKg, bodyweightKg: $0.bodyweightKg)
                               })
            },
            runs: runSessions.map {
                RunRow(date: $0.date, weekIndex: $0.weekIndex, dayIndex: $0.dayIndex,
                       durationSec: $0.durationSec, distanceKm: $0.distanceKm,
                       avgHeartRate: $0.avgHeartRate, rpe: $0.rpe)
            },
            stretchSessions: stretches.map {
                StretchRow(date: $0.date, routineName: $0.routineName, durationSec: $0.durationSec)
            },
            reminders: reminders.map {
                ReminderRow(title: $0.title, fireAt: $0.fireAt, recurrence: $0.recurrenceRaw,
                            enabled: $0.enabled, completed: $0.completedAt != nil)
            },
            todos: todos.map {
                TodoRow(title: $0.title, priority: $0.priorityRaw, dueDate: $0.dueDate, done: $0.doneAt != nil)
            },
            workouts: allWorkouts.map {
                WorkoutRow(date: $0.date, type: $0.typeRaw, state: $0.stateRaw,
                           source: $0.sourceRaw, title: $0.title, durationMin: $0.durationMin,
                           avgBPM: $0.avgBPM, distanceKm: $0.distanceKm,
                           inclinePercent: $0.inclinePercent)
            },
            // Cap the exported transcript: this export runs on every plan
            // generation, and the eval only ever reads recent conversations.
            chatTurns: chatTurns.sorted { $0.timestamp < $1.timestamp }
                .suffix(chatTurnExportLimit).map {
                    ChatTurnRow(timestamp: $0.timestamp, role: $0.roleRaw,
                                content: String($0.content.prefix(2000)),
                                isPlan: $0.planJSON != nil)
                },
            voiceNotes: voiceNotes.sorted { $0.date < $1.date }.map {
                VoiceNoteRow(date: $0.date, durationSec: $0.durationSec,
                             locale: $0.localeID, transcript: $0.transcript,
                             audioFile: $0.audioFileName)
            }
        )

        let logEntries = DiagnosticsSync.entries(from: logs)
        let last = logs.max { $0.startedAt < $1.startedAt }
        let heartbeat = Heartbeat(
            schemaVersion: schemaVersion, writtenAt: now, writtenAtEpoch: now.timeIntervalSince1970,
            appVersion: appVersion, buildNumber: buildNumber, device: deviceModel,
            counts: ["plans": plans.count, "events": events.count, "checkIns": checkIns.count,
                     "leisure": leisure.count, "routine": routine.count, "genLogs": logs.count,
                     "lifts": liftSessions.count, "runs": runSessions.count, "stretches": stretches.count,
                     "reminders": reminders.count, "todos": todos.count,
                     "workouts": allWorkouts.count, "chatTurns": chatTurns.count,
                     "voiceNotes": voiceNotes.count],
            lastPlanAt: last?.startedAt, lastPlanTrigger: last?.trigger.rawValue,
            lastPlanOutcome: last?.outcome.rawValue
        )

        // Encode on the main actor (where the shared IST formatter lives), then
        // hand the raw bytes to a detached task for the blocking ubiquity lookup
        // and file-coordinated write.
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .formatted(.istTimestamp)
        let stateData = try? enc.encode(snapshot)
        let heartbeatData = try? enc.encode(heartbeat)
        Task.detached(priority: .utility) {
            if let stateData { writeData(stateData, fileName: "state-latest.json") }
            if let heartbeatData { writeData(heartbeatData, fileName: "heartbeat.json") }
        }
        DiagnosticsSync.write(logEntries, now: now)
        // Mirror voice-note audio to iCloud (VoiceNotes/) and prune past the
        // 30-day retention window — the Whisper eval reads these.
        VoiceNoteSync.export(context: context, now: now)
        if includeRawBackup { DataBackup.writeToICloud(now: now) }
    }

    /// The app's iCloud Drive Documents folder (the same one DiagnosticsSync and
    /// DataBackup write to). Nil if iCloud Documents isn't available. May block —
    /// call off the main thread.
    nonisolated private static func documentsURL() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: "iCloud.abhimanyusingh.me.Jeeves") else { return nil }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    /// File-coordinate + atomic-write pre-encoded bytes into the iCloud folder.
    @discardableResult
    nonisolated private static func writeData(_ data: Data, fileName: String) -> Bool {
        guard let docs = documentsURL() else {
            // The single most important failure to surface: iOS handed back no
            // ubiquity URL, so NOTHING can ever reach the Mac. Silently
            // returning here is what let the export channel look healthy for
            // days while delivering nothing.
            record(failure: "iCloud Drive unavailable to the app (no ubiquity container URL)")
            return false
        }
        let url = docs.appendingPathComponent(fileName)
        var coordinationError: NSError?
        var wrote = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                try data.write(to: target, options: .atomic)
                wrote = true
            } catch {
                record(failure: "write failed for \(fileName): \(error.localizedDescription)")
            }
        }
        if let coordinationError {
            record(failure: "file coordination failed for \(fileName): \(coordinationError.localizedDescription)")
        }
        if wrote { record(success: fileName) }
        return wrote
    }

    // MARK: Channel health
    //
    // An export that fails silently is indistinguishable from an app that is
    // simply healthy and quiet. These few lines are what let the daily
    // diagnosis say "the phone can't reach iCloud" instead of guessing.

    private static let successKey = "jeeves.sync.lastSuccessAt"
    private static let failureKey = "jeeves.sync.lastFailure"
    private static let failureAtKey = "jeeves.sync.lastFailureAt"

    nonisolated static func record(success fileName: String) {
        let d = UserDefaults.standard
        d.set(Date(), forKey: successKey)
        d.removeObject(forKey: failureKey)
        d.removeObject(forKey: failureAtKey)
    }

    nonisolated static func record(failure reason: String) {
        let d = UserDefaults.standard
        d.set(reason, forKey: failureKey)
        d.set(Date(), forKey: failureAtKey)
    }

    /// What the last export attempt actually did — read by the anomaly scan so
    /// a dead channel reports itself on the next cable pull even when iCloud
    /// itself is the thing that's broken.
    nonisolated static var health: (lastSuccess: Date?, failure: String?, failedAt: Date?) {
        let d = UserDefaults.standard
        return (d.object(forKey: successKey) as? Date,
                d.string(forKey: failureKey),
                d.object(forKey: failureAtKey) as? Date)
    }

    /// Whether the last export actually LEFT the phone.
    ///
    /// A write to the ubiquity container succeeds locally even when iCloud
    /// isn't syncing this app — which is exactly how the export reported
    /// success for days while the Mac received nothing. Uploading is the
    /// property that matters, so it's the one reported.
    ///
    /// nil means there's nothing to judge (no container, or no file yet).
    nonisolated static func uploadState() -> (uploaded: Bool, error: String?)? {
        guard let docs = documentsURL() else { return nil }
        let url = docs.appendingPathComponent("heartbeat.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let keys: Set<URLResourceKey> = [.ubiquitousItemIsUploadedKey,
                                         .ubiquitousItemUploadingErrorKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let uploaded = values.ubiquitousItemIsUploaded ?? false
        let error = (values.ubiquitousItemUploadingError as NSError?)?.localizedDescription
        return (uploaded, error)
    }
}
