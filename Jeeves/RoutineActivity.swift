//
//  RoutineActivity.swift
//  Jeeves
//
//  The user's daily routine, made editable. Historically the routine was a
//  hardcoded `Baseline.activities` array; this persists it as SwiftData so the
//  user can add, edit, reorder, and toggle activities on/off from the Routine
//  screen — and so the planner reasons over THEIR routine, not a fixed list.
//  All stored properties carry defaults so the model is CloudKit-ready.
//

import Foundation
import SwiftData

@Model
final class RoutineActivity {
    var name: String = ""
    var durationMinutes: Int = 30
    var tierRaw: String = PriorityTier.flexible.rawValue
    var note: String? = nil
    var enabled: Bool = true          // off = kept in the routine but skipped when planning
    var sortOrder: Int = 0            // fill order the planner respects

    var tier: PriorityTier {
        get { PriorityTier(rawValue: tierRaw) ?? .flexible }
        set { tierRaw = newValue.rawValue }
    }

    /// The value type the planner prompt consumes.
    var asBaseline: BaselineActivity {
        BaselineActivity(name: name, durationMinutes: durationMinutes, tier: tier, note: note)
    }

    init(name: String, durationMinutes: Int, tier: PriorityTier, note: String? = nil, enabled: Bool = true, sortOrder: Int) {
        self.name = name
        self.durationMinutes = durationMinutes
        self.tierRaw = tier.rawValue
        self.note = note
        self.enabled = enabled
        self.sortOrder = sortOrder
    }
}

extension Baseline {
    /// Seeds the editable routine with the default activities the first time the
    /// app runs, so an empty store becomes the user's starting routine — which
    /// they can then edit. No-op once any routine activity exists.
    static func seed(into context: ModelContext) {
        let isEmpty = ((try? context.fetchCount(FetchDescriptor<RoutineActivity>())) ?? 0) == 0
        guard isEmpty else { return }
        for (i, a) in activities.enumerated() {
            context.insert(RoutineActivity(name: a.name, durationMinutes: a.durationMinutes,
                                           tier: a.tier, note: a.note, enabled: true, sortOrder: i))
        }
        try? context.save()
    }

    /// The enabled routine in fill order, or the hardcoded default when the
    /// store hasn't been seeded yet (e.g. tests, first launch mid-plan).
    static func routine(from activities: [RoutineActivity]) -> [BaselineActivity] {
        let enabled = activities.filter(\.enabled).sorted { $0.sortOrder < $1.sortOrder }
        return enabled.isEmpty ? self.activities : enabled.map(\.asBaseline)
    }
}
