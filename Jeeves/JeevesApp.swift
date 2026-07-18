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
        }
        .modelContainer(sharedModelContainer)
    }
}
