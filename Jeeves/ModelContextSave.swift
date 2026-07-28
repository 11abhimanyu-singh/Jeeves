//
//  ModelContextSave.swift
//  Jeeves
//
//  A save that doesn't swallow failures. A bare `try?` on save() silently
//  drops persistence errors, so a failed write can leave the UI showing success
//  while the data never actually landed (a lost workout, a plan that shows in
//  chat but not on the Day Planner). saveOrLog() logs the error — and asserts in
//  debug so it surfaces in testing — and reports success, so callers can couple
//  a success flag to it (e.g. only mark a run "logged" if the save really took).
//

import Foundation
import SwiftData
import os

private let saveLog = Logger(subsystem: "abhimanyusingh.me.Jeeves", category: "swiftdata")

extension ModelContext {
    /// Save pending changes, surfacing failures instead of ignoring them.
    /// Returns whether the save succeeded (true when there was nothing to save).
    @discardableResult
    func saveOrLog(_ label: String = #function) -> Bool {
        guard hasChanges else { return true }
        do {
            try save()
            return true
        } catch {
            saveLog.error("SwiftData save failed [\(label, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            assertionFailure("SwiftData save failed [\(label)]: \(error)")
            return false
        }
    }
}
