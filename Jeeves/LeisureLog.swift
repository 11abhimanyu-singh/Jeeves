//
//  LeisureLog.swift
//  Jeeves
//
//  Logs how discretionary time (TV, music, photography, extra interview
//  practice) actually got spent, so Claude can dynamically rebalance the
//  next day's split rather than using fixed durations.
//

import Foundation
import SwiftData

enum DiscretionaryActivity: String, Codable, CaseIterable {
    case tv = "TV"
    case music = "Music"
    case photography = "Photography"
    case extraInterviewPrep = "Extra interview prep"
}

@Model
final class LeisureLog {
    var date: Date
    var activityRaw: String
    var durationMinutes: Double

    var activity: DiscretionaryActivity {
        get { DiscretionaryActivity(rawValue: activityRaw) ?? .tv }
        set { activityRaw = newValue.rawValue }
    }

    init(date: Date, activity: DiscretionaryActivity, durationMinutes: Double) {
        self.date = date
        self.activityRaw = activity.rawValue
        self.durationMinutes = durationMinutes
    }
}//
//  Leisurelog.swift
//  Jeeves
//
//  Created by Abhimanyu Singh on 17/07/26.
//

