//
//  JeevesApp.swift
//  Jeeves
//
//  Created by Abhimanyu Singh on 17/07/26.
//

import SwiftUI
import UIKit
import SwiftData

/// The one thing a SwiftUI App cannot express: iOS delivers background-transfer
/// completions to the APP DELEGATE, and refuses to keep waking an app that never
/// calls the handler back. Without this, a plan that finished while the app was
/// terminated is simply never received — which is the entire point of the
/// background session.
final class JeevesAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundPlanSession.identifier else {
            completionHandler(); return
        }
        Task { @MainActor in
            BackgroundPlanSession.shared.systemCompletionHandler = completionHandler
        }
    }
}

@main
struct JeevesApp: App {
    @UIApplicationDelegateAdaptor(JeevesAppDelegate.self) private var appDelegate

    init() {
        // Show reminders even while the app is open.
        NotificationService.configure()
        // Register the background handlers before launch finishes (a hard
        // requirement of BGTaskScheduler): commute re-pricing and the overnight
        // auto-planner that has the coming days ready before the user wakes.
        CommuteBackgroundRefresh.register(container: sharedModelContainer)
        AutoPlanService.register(container: sharedModelContainer)
        // Reattach to any plan transfer still in flight from a previous run.
        // No-op while the background session is switched off.
        BackgroundPlanSession.activate(container: sharedModelContainer)
        // A plan can finish while nothing is on screen — after the app was
        // suspended, or terminated and relaunched to receive it. Commit it to
        // the day it was for rather than throwing away work already paid for.
        // Hoisted: inside a struct's init, `self` is mutating and cannot be
        // captured by an escaping closure.
        let container = sharedModelContainer
        BackgroundPlanSession.onOrphanedResult = { data, ticket in
            guard let plan = PlanGenerationService.plan(fromResponse: data) else { return }
            Task { @MainActor in
                await PlanCoordinator.commit(
                    .init(plan: plan, isOffline: false, error: nil),
                    on: ticket.day, context: container.mainContext)
                await NotificationService.notifyPlanReady(isOffline: false)
            }
        }
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
