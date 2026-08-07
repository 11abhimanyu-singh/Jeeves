//
//  JeevesApp.swift
//  Jeeves
//
//  Created by Abhimanyu Singh on 17/07/26.
//

import SwiftUI
import SwiftData

@main
struct JeevesApp: App {
    init() {
        // Show reminders even while the app is open.
        NotificationService.configure()
        // Register the background handlers before launch finishes (a hard
        // requirement of BGTaskScheduler). Commute re-pricing is the only one
        // left: the overnight auto-planner is gone. It built four days while
        // the user slept and committed them, and days nobody chose were kept
        // 0%, 0%, 0%, 13%, 36% of the time. The 07:00 offer replaced it, and a
        // notification needs no background task to fire.
        CommuteBackgroundRefresh.register(container: sharedModelContainer)
        // The Watch workout inbox needs the store to file finished workouts,
        // and old lift/run logs get wrapped into Workouts once.
        WatchLink.shared.configure(container: sharedModelContainer)
        Workout.migrateIfNeeded(context: sharedModelContainer.mainContext)
        // Collapse duplicate calendar rows from the pre-idempotent sync era,
        // and repair rows whose times got corrupted (end before start).
        DailyEvent.dedupeExternal(context: sharedModelContainer.mainContext)
        DailyEvent.repairInvalidTimes(context: sharedModelContainer.mainContext)
        // Travel store repairs — launch runs only the provably-safe set
        // (content-keyed fixes, window GROWTH, plan sweep, fail-closed nudge
        // purge). Destructive tidying (merges, orphan deletion) is
        // user-invoked via the clean_travel_data chat tool, never automatic:
        // a launch mid-CloudKit-sync sees half-imported data, and deletes
        // propagate to every device.
        let context = sharedModelContainer.mainContext
        Task {
            TravelRepair.repairSafe(context: context)
            await TravelRepair.repairWindows(context: context)
            await TravelGuard.sweep(context: context)
            await TravelNotifier.purgeOrphans(context: context)
            // Scan for anomalies (behavioral + structural) and mirror the
            // digest to iCloud Drive for the Mac-side daily summary. Scans
            // and narrates only — never repairs; the user designs fixes and
            // UX from what this surfaces.
            AnomalyScan.writeDigest(context: context)
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            CheckIn.self,
            JobApplication.self,
            PrepSession.self,
            LeisureLog.self,
            DailyPlanState.self,
            Book.self,
            ReadingLog.self,
            SavedLocation.self,
            DailyEvent.self,
            ChatTurn.self,
            RoutineActivity.self,
            PlanGenerationLog.self,
            LiftSession.self,
            LiftSet.self,
            RunSession.self,
            StretchLog.self,
            Reminder.self,
            Todo.self,
            Workout.self,
            VoiceNote.self,
            Trip.self,
            TravelSegment.self,
            TripStay.self,
            AppEvent.self,
            CalendarTombstone.self,
            ActivitySession.self,
        ])
        // Sync to the user's private iCloud database so their data backs up and
        // follows them across devices. The iCloud/CloudKit capability is present
        // (Jeeves.entitlements), so this initializes cleanly on device and
        // handles a signed-out iCloud account gracefully (local until sign-in).
        //
        // The XCTest host has no usable iCloud in its sandbox, so tests use a
        // plain local store — CloudKit init there crashes the runner.
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let configuration: ModelConfiguration = isTesting
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            : ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                 cloudKitDatabase: .private("iCloud.abhimanyusingh.me.Jeeves"))
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // The palette is a hardcoded light theme; system colors (text
                // fields, .primary/.secondary) would flip to white in dark mode
                // and vanish on the light background. Pin light until the
                // dark-warm redesign (PRD §3) lands and handles both properly.
                .preferredColorScheme(.light)
        }
        .modelContainer(sharedModelContainer)
    }
}
