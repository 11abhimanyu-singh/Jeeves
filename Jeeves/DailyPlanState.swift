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

    init(date: Date, hasGymToday: Bool, gymMinute: Int?, planConfirmed: Bool = false) {
        self.date = date
        self.hasGymToday = hasGymToday
        self.gymMinute = gymMinute
        self.planConfirmed = planConfirmed
    }
}
