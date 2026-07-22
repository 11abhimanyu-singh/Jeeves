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
        // Prefer syncing to the user's private iCloud database so their data
        // backs up and follows them across devices. This only works once the
        // iCloud/CloudKit capability is added to the target (Signing &
        // Capabilities in Xcode); until then, fall back to a plain local store
        // so the app still runs. No data is lost in the fallback — the local
        // store is migrated into the CloudKit-backed one once sync is enabled.
        let cloudConfig = ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.abhimanyusingh.me.Jeeves"))
        if let container = try? ModelContainer(for: schema, configurations: [cloudConfig]) {
            return container
        }

        let localConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [localConfig])
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
