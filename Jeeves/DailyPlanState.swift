//
//  DailyPlanState.swift
//  Jeeves
//
//  Persists the one input the planner needs each day: whether there's a
//  gym session, and what time weightlifting starts. Without this, the
//  gym time was just @State and reset every time the app relaunched.
//

import Foundation
import SwiftData

@Model
final class DailyPlanState {
    var date: Date          // startOfDay — one record per day
    var hasGymToday: Bool
    var gymMinute: Int?     // minutes-since-midnight for weightlifting start
    var planConfirmed: Bool = false // true once the gym-input tile has been submitted or dismissed

    // The committed day plan for this date (encoded GeneratedPlan). This is what
    // makes "Plan my day" persist — it survives relaunches and shows on the
    // Day Planner, rather than living only in the chat.
    var generatedPlanJSON: String? = nil
    var generatedPlanIsOffline: Bool = false

    init(date: Date, hasGymToday: Bool, gymMinute: Int?, planConfirmed: Bool = false) {
        self.date = date
        self.hasGymToday = hasGymToday
        self.gymMinute = gymMinute
        self.planConfirmed = planConfirmed
    }

    var plan: GeneratedPlan? {
        guard let generatedPlanJSON, let data = generatedPlanJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GeneratedPlan.self, from: data)
    }

    func storePlan(_ plan: GeneratedPlan, isOffline: Bool) {
        generatedPlanJSON = (try? JSONEncoder().encode(plan)).flatMap { String(data: $0, encoding: .utf8) }
        generatedPlanIsOffline = isOffline
    }
}
