//
//  JobPrep.swift
//  Jeeves
//
//  Tracks job applications and interview prep sessions, so the day planner
//  can ask Claude to split practice time toward your weakest area.
//

import Foundation
import SwiftData

@Model
final class JobApplication {
    var date: Date          // startOfDay — one record per day you applied
    var appliedToday: Bool
    var company: String?    // optional, just for your own reference
    var notes: String?

    init(date: Date, appliedToday: Bool, company: String? = nil, notes: String? = nil) {
        self.date = date
        self.appliedToday = appliedToday
        self.company = company
        self.notes = notes
    }
}

enum PrepCategory: String, Codable, CaseIterable {
    case productSense = "Product Sense"
    case execution = "Execution"
    case strategy = "Strategy"
    case behavioral = "Behavioral"
    case reading = "Reading"
}

@Model
final class PrepSession {
    var date: Date
    var categoryRaw: String     // stores PrepCategory.rawValue (SwiftData needs primitive types)
    var durationMinutes: Double
    var rating: Int?            // optional 1–5 self-rating of how it went

    var category: PrepCategory {
        get { PrepCategory(rawValue: categoryRaw) ?? .reading }
        set { categoryRaw = newValue.rawValue }
    }

    init(date: Date, category: PrepCategory, durationMinutes: Double, rating: Int? = nil) {
        self.date = date
        self.categoryRaw = category.rawValue
        self.durationMinutes = durationMinutes
        self.rating = rating
    }
}
