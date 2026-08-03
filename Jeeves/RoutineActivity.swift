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

/// The upper layer a routine activity can belong to. Interview prep and the
/// gym are single things you either do or don't, made of parts you tune
/// separately — 45 minutes of Product Sense and none of Strategy is a normal
/// week, and mobility without cardio is a normal session. A flat list can say
/// neither: the four prep categories used to live inside one 100-minute row as
/// a sentence in its note, and the three gym parts were durations hardcoded in
/// two files with the prompt forbidding the model to change them.
enum RoutineGroup: String, CaseIterable, Codable {
    case none = ""
    case interviewPrep = "Interview prep"
    case gym = "Gym"

    var title: String { self == .none ? "" : rawValue }
}

@Model
final class RoutineActivity {
    var name: String = ""
    var durationMinutes: Int = 30
    var tierRaw: String = PriorityTier.flexible.rawValue
    var note: String? = nil
    var enabled: Bool = true          // off = kept in the routine but skipped when planning
    var sortOrder: Int = 0            // fill order the planner respects
    /// Which upper layer this belongs to. Empty = a standalone activity.
    var groupRaw: String = RoutineGroup.none.rawValue
    /// For prep children, the PrepCategory this row logs against, so a block
    /// can be judged by its own evidence instead of every prep block sharing
    /// one verdict. Empty for everything else.
    var prepCategoryRaw: String = ""

    var tier: PriorityTier {
        get { PriorityTier(rawValue: tierRaw) ?? .flexible }
        set { tierRaw = newValue.rawValue }
    }

    var group: RoutineGroup {
        get { RoutineGroup(rawValue: groupRaw) ?? .none }
        set { groupRaw = newValue.rawValue }
    }

    var prepCategory: PrepCategory? {
        get { prepCategoryRaw.isEmpty ? nil : PrepCategory(rawValue: prepCategoryRaw) }
        set { prepCategoryRaw = newValue?.rawValue ?? "" }
    }

    /// What the planner sees. A child carries its group in the name so the
    /// generated block is self-describing — "Interview prep — Product Sense"
    /// rather than a bare "Product Sense" that nothing downstream can classify.
    var plannerName: String {
        group == .none ? name : "\(group.rawValue) — \(name)"
    }

    /// The value type the planner prompt consumes.
    var asBaseline: BaselineActivity {
        BaselineActivity(name: plannerName, durationMinutes: durationMinutes, tier: tier, note: note)
    }

    init(name: String, durationMinutes: Int, tier: PriorityTier, note: String? = nil,
         enabled: Bool = true, sortOrder: Int,
         group: RoutineGroup = .none, prepCategory: PrepCategory? = nil) {
        self.name = name
        self.durationMinutes = durationMinutes
        self.tierRaw = tier.rawValue
        self.note = note
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.groupRaw = group.rawValue
        self.prepCategoryRaw = prepCategory?.rawValue ?? ""
    }
}

extension Baseline {
    /// The four question categories, in the order the neglect ranking declares
    /// them. Reading is deliberately absent: it is prep, but it is not practice.
    static let practiceCategories: [PrepCategory] = [.productSense, .execution, .strategy, .behavioral]

    /// The gym session's parts. Durations were previously hardcoded here and in
    /// the prompt; they are now only the STARTING values for the editable rows.
    static let gymParts: [(name: String, minutes: Int)] = [
        ("Mobility", 20), ("Weightlifting", 70), ("Cardio", 35),
    ]

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
        context.saveOrLog()
        regroup(in: context)
    }

    /// One-time restructure of an already-seeded routine into groups.
    ///
    /// The single "Interview prep — practice" row becomes four independently
    /// timed, independently switchable children, splitting its minutes between
    /// them; "Interview prep — Reading" joins the same parent as the reading
    /// category; and the gym's three parts arrive as rows for the first time,
    /// since the gym was previously a per-day anchor with its durations frozen
    /// in the prompt. Idempotent: it looks for what it would create and stops.
    static func regroup(in context: ModelContext) {
        var rows = (try? context.fetch(FetchDescriptor<RoutineActivity>())) ?? []
        guard !rows.isEmpty else { return }
        var changed = false
        var nextSort = (rows.map(\.sortOrder).max() ?? 0) + 1

        // --- Interview prep ---
        if !rows.contains(where: { $0.group == .interviewPrep && $0.prepCategory == .productSense }) {
            let practice = rows.first {
                $0.group == .none && $0.name.localizedCaseInsensitiveContains("practice")
                    && $0.name.localizedCaseInsensitiveContains("interview")
            }
            let total = practice?.durationMinutes ?? 100
            let tier = practice?.tier ?? .important
            let each = max(15, total / practiceCategories.count)
            let order = practice?.sortOrder ?? nextSort
            for (i, category) in practiceCategories.enumerated() {
                context.insert(RoutineActivity(
                    name: category.rawValue, durationMinutes: each, tier: tier,
                    note: nil, enabled: practice?.enabled ?? true,
                    sortOrder: order + i, group: .interviewPrep, prepCategory: category))
            }
            if let practice { context.delete(practice) }
            nextSort = order + practiceCategories.count
            changed = true
        }
        // The prep-reading row keeps its own duration and tier — it is a
        // separate activity from practice, only now it sits under the same
        // parent and declares the category it logs against.
        if let reading = rows.first(where: {
            $0.group == .none && $0.name.localizedCaseInsensitiveContains("interview")
                && $0.name.localizedCaseInsensitiveContains("reading")
        }) {
            reading.name = PrepCategory.reading.rawValue
            reading.group = .interviewPrep
            reading.prepCategory = .reading
            changed = true
        }

        // --- Gym ---
        if !rows.contains(where: { $0.group == .gym }) {
            for (i, part) in gymParts.enumerated() {
                context.insert(RoutineActivity(
                    name: part.name, durationMinutes: part.minutes, tier: .mustDo,
                    note: nil, enabled: true, sortOrder: nextSort + i, group: .gym))
            }
            changed = true
        }

        if changed {
            context.saveOrLog("routine.regroup")
            rows = (try? context.fetch(FetchDescriptor<RoutineActivity>())) ?? []
        }
    }

    /// The enabled routine in fill order, or the hardcoded default when the
    /// store hasn't been seeded yet (e.g. tests, first launch mid-plan).
    /// Gym children are excluded — the gym is placed as a per-day anchor, not
    /// filled like a routine activity, and its parts are read separately.
    /// `selection` narrows it further to just this DAY's choice. Filtering here
    /// — once, at the point the routine becomes a value — is what keeps the
    /// online prompt and the offline fallback from disagreeing about which
    /// activities the day contains.
    static func routine(from activities: [RoutineActivity],
                        selection: ActivitySelection = .routine) -> [BaselineActivity] {
        let enabled = activities
            .filter { $0.enabled && $0.group != .gym && selection.includes($0.plannerName) }
            .sorted { $0.sortOrder < $1.sortOrder }
        // An empty result falls back to the hardcoded defaults ONLY when the
        // store simply hasn't been seeded. A day the user deliberately emptied
        // must stay empty — falling back there would refill the day they had
        // just asked to clear, which is the bug this whole path exists to fix.
        if enabled.isEmpty, !selection.isExplicit { return self.activities }
        return enabled.map(\.asBaseline)
    }

    /// The gym session as configured: enabled parts, in order, with their own
    /// durations. Falls back to the historical fixed session when nothing is
    /// stored yet, so a plan generated before the migration still works.
    static func gymSession(from activities: [RoutineActivity]) -> [(name: String, minutes: Int)] {
        let parts = activities
            .filter { $0.group == .gym && $0.enabled }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { (name: $0.name, minutes: $0.durationMinutes) }
        return parts.isEmpty ? gymParts : parts
    }
}
