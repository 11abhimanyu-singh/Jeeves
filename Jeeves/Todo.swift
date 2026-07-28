//
//  Todo.swift
//  Jeeves
//
//  SwiftData model for one untimed to-do. Unlike routine activities (which the
//  planner slots into the day), a Todo is just a task on a list: it has a
//  priority, an optional due date, and a done timestamp. All stored properties
//  carry defaults and enums persist as a raw String so the model is
//  CloudKit-ready.
//

import Foundation
import SwiftData

/// How urgent a to-do is. Drives both the row's colored dot and the open-list
/// ordering (high floats to the top).
enum TodoPriority: String, CaseIterable {
    case high
    case medium
    case low

    /// Human-facing label for pickers and badges.
    var label: String {
        switch self {
        case .high:   return "High"
        case .medium: return "Medium"
        case .low:    return "Low"
        }
    }

    /// Fill order for the open list: high = 0 … low = 2.
    var sortRank: Int {
        switch self {
        case .high:   return 0
        case .medium: return 1
        case .low:    return 2
        }
    }
}

@Model
final class Todo {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var priorityRaw: String = TodoPriority.medium.rawValue
    var dueDate: Date? = nil
    var context: String = ""            // free-form tag, e.g. "Home", "Errands"
    var doneAt: Date? = nil             // set when completed; nil = open
    var sortOrder: Int = 0              // manual order within a priority tier

    /// Typed accessor over the persisted raw string.
    var priority: TodoPriority {
        get { TodoPriority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }

    /// A to-do is done once it has a completion timestamp.
    var isDone: Bool { doneAt != nil }

    init(
        title: String = "",
        notes: String = "",
        priority: TodoPriority = .medium,
        dueDate: Date? = nil,
        context: String = "",
        sortOrder: Int = 0
    ) {
        self.title = title
        self.notes = notes
        self.priorityRaw = priority.rawValue
        self.dueDate = dueDate
        self.context = context
        self.sortOrder = sortOrder
    }
}
