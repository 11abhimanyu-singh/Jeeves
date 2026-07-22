//
//  CheckIn.swift
//  Jeeves
//
//  SwiftData model for one day's fitness accountability entry.
//

import Foundation
import SwiftData

@Model
final class CheckIn {
    var date: Date = Date.distantPast   // normalized to start-of-day, one CheckIn per day
    var workedOut: Bool = false
    var weightTraining: Bool = false
    var stretching: Bool = false
    var mobility: Bool = false
    var cardio: Bool = false
    var cardioType: String?     // "Running" or "Inclined Walk"
    var cardioDuration: Double? // minutes
    var cardioIncline: Double?  // percent

    init(
        date: Date,
        workedOut: Bool,
        weightTraining: Bool = false,
        stretching: Bool = false,
        mobility: Bool = false,
        cardio: Bool = false,
        cardioType: String? = nil,
        cardioDuration: Double? = nil,
        cardioIncline: Double? = nil
    ) {
        self.date = date
        self.workedOut = workedOut
        self.weightTraining = weightTraining
        self.stretching = stretching
        self.mobility = mobility
        self.cardio = cardio
        self.cardioType = cardioType
        self.cardioDuration = cardioDuration
        self.cardioIncline = cardioIncline
    }
}

extension Date {
    /// Strips time so each day maps to exactly one CheckIn.
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }
}
