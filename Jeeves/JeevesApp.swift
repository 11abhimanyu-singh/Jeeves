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
        ])
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
