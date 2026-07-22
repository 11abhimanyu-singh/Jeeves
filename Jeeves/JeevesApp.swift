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
        // Register the background commute-refresh handler before launch finishes
        // (a hard requirement of BGTaskScheduler).
        CommuteBackgroundRefresh.register(container: sharedModelContainer)
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
        ])
        // Local store. CloudKit sync is intentionally NOT enabled here yet:
        // pointing the container at a CloudKit database WITHOUT the iCloud
        // entitlement present is a hard OS-level termination on device (not a
        // catchable error), so it must only be turned on AFTER the iCloud/
        // CloudKit capability is added to the target in Xcode. Once that's done,
        // re-enable by adding `cloudKitDatabase:
        // .private("iCloud.abhimanyusingh.me.Jeeves")` to this configuration —
        // the schema is already CloudKit-ready.
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
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
