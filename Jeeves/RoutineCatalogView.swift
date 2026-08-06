//
//  RoutineCatalogView.swift
//  Jeeves
//
//  Edit the daily routine Jeeves plans around: add/remove activities, change a
//  duration or priority tier, toggle one off to skip it, and reorder the fill
//  sequence. Anchors (gym, events, sleep) are set per day elsewhere — this is
//  the standing routine only.
//

import SwiftUI
import SwiftData

struct RoutineCatalogView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RoutineActivity.sortOrder) private var activities: [RoutineActivity]
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case add
        case edit(RoutineActivity)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let a): return String(a.persistentModelID.hashValue)
            }
        }
    }

    /// Standalone rows keep the reorderable list; grouped ones get their own
    /// section per parent. Interview prep and the gym are single things made of
    /// parts you tune separately — four practice categories inside one
    /// 100-minute row, or three gym durations frozen in a prompt, could say
    /// neither.
    private var ungrouped: [RoutineActivity] {
        activities.filter { $0.group == .none }.sorted { $0.sortOrder < $1.sortOrder }
    }
    private func children(_ g: RoutineGroup) -> [RoutineActivity] {
        activities.filter { $0.group == g }.sorted { $0.sortOrder < $1.sortOrder }
    }
    private var groupsPresent: [RoutineGroup] {
        RoutineGroup.allCases.filter { $0 != .none && !children($0).isEmpty }
    }

    var body: some View {
        Form {
            Section {
                ForEach(ungrouped) { activity in
                    Button { sheet = .edit(activity) } label: { row(activity) }
                        .buttonStyle(.plain)
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            } header: {
                Text("Your daily routine")
            } footer: {
                Text("Jeeves plans each day around these. Toggle one off to keep it in the list but skip it, or tap to change its time and priority. Drag to reorder the fill sequence.")
            }
            .listRowBackground(Color.surface)

            ForEach(groupsPresent, id: \.self) { group in
                Section {
                    ForEach(children(group)) { activity in
                        Button { sheet = .edit(activity) } label: { row(activity) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(group.title)
                        Spacer()
                        // The parent switch is derived, not stored: on when any
                        // child is on, and turning it off silences all of them.
                        Toggle("", isOn: Binding(
                            get: { children(group).contains(where: \.enabled) },
                            set: { on in
                                for c in children(group) { c.enabled = on }
                                context.saveOrLog("routine.group.toggle")
                            }))
                        .labelsHidden()
                        .tint(Color.accent)
                    }
                } footer: {
                    Text(group == .gym
                         ? "The parts of a gym session, each with its own length. Switch one off to skip it; the gym's start time is still set per day in Today's anchors."
                         : "Each category is its own block with its own length, and is logged separately. Reading is prep, but it isn't practice — it's tracked apart from the four question categories.")
                }
                .listRowBackground(Color.surface)
            }

            Section {
                Button { sheet = .add } label: {
                    Label("Add activity", systemImage: "plus.circle.fill").foregroundStyle(Color.accentDeep)
                }
            }
            .listRowBackground(Color.surface)
        }
        .jeevesFormChrome()
        .navigationTitle("Daily routine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton().tint(Color.accent) }
        .onAppear { Baseline.seed(into: context); Baseline.regroup(in: context) }
        .sheet(item: $sheet) { s in
            switch s {
            case .add: RoutineActivityEditor(existing: nil, nextSort: (activities.map(\.sortOrder).max() ?? -1) + 1)
            case .edit(let a): RoutineActivityEditor(existing: a, nextSort: 0)
            }
        }
    }

    private func row(_ a: RoutineActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name.isEmpty ? "Untitled" : a.name)
                        .font(.serif(16))
                        .foregroundStyle(a.enabled ? Color.textPrimary : Color.textMuted)
                    Text("\(a.durationMinutes) min · \(a.tier.rawValue) · \(a.cadence.description)")
                        .font(.ui(12.5)).foregroundStyle(Color.textSoft)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { a.enabled },
                    set: { a.enabled = $0; context.saveOrLog() }
                ))
                .labelsHidden().tint(Color.accent)
            }
            // The switch answers "do I do this at all"; the chips answer "which
            // days". A row that is off keeps its days, so switching it back on
            // restores the shape it had rather than a blank week.
            weekdayStrip(a)
        }
        .padding(.vertical, 2)
    }

    /// Seven taps, Monday-first. Writes straight through like the enabled
    /// toggle above — the editor sheet is @State-buffered, but a row control
    /// that needs a Save button to take effect reads as broken.
    private func weekdayStrip(_ a: RoutineActivity) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(Cadence.orderedWeekdays.enumerated()), id: \.offset) { i, weekday in
                let on = a.cadence.isDue(onWeekday: weekday)
                Button {
                    toggle(weekday, on: a)
                } label: {
                    Text(Cadence.initials[i])
                        .font(.ui(11.5, weight: .semibold))
                        .frame(minWidth: 26, minHeight: 26)
                        .foregroundStyle(on ? Color.accentDeep : Color.textMuted)
                        .background(Circle().fill(on ? Color.accent.opacity(0.15) : Color.surface))
                        .overlay(Circle().stroke(on ? Color.accent : Color.textPrimary.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .opacity(a.enabled ? 1 : 0.45)
                .accessibilityLabel(Cadence.shortLabel(weekday))
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }

    /// Turning off the last remaining day means "every day" rather than "never":
    /// an activity that runs on no day at all is what the on/off switch is for,
    /// and leaving a row that can never be planned is a trap.
    private func toggle(_ weekday: Int, on a: RoutineActivity) {
        var days = a.cadence.isEveryDay ? Set(1...7) : a.cadence.weekdays
        if days.contains(weekday) { days.remove(weekday) } else { days.insert(weekday) }
        a.cadence = (days.isEmpty || days.count == 7) ? .everyDay : Cadence(weekdays: days)
        context.saveOrLog("routine.cadence")
    }

    // Both index into `ungrouped`, which is what the list actually shows.
    // Indexing the full `activities` array would delete or reorder whichever
    // grouped row happened to sit at that position — the wrong activity, and
    // silently.
    private func delete(_ offsets: IndexSet) {
        let rows = ungrouped
        for i in offsets where rows.indices.contains(i) { context.delete(rows[i]) }
        context.saveOrLog()
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        var reordered = ungrouped
        reordered.move(fromOffsets: offsets, toOffset: destination)
        // Renumber only these rows, into the slots they already occupy, so a
        // reorder here can't renumber a group's children out from under it.
        let slots = ungrouped.map(\.sortOrder).sorted()
        for (i, a) in reordered.enumerated() where slots.indices.contains(i) {
            a.sortOrder = slots[i]
        }
        context.saveOrLog()
    }
}

// MARK: - Add / edit one activity

struct RoutineActivityEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let existing: RoutineActivity?
    let nextSort: Int

    @State private var name = ""
    @State private var minutes = 30.0
    @State private var tier: PriorityTier = .flexible

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                } footer: {
                    Text("What you want to do — e.g. \"Reading habit\", \"Language practice\".")
                }
                .listRowBackground(Color.surface)

                Section {
                    Stepper("Duration: \(Int(minutes)) min", value: $minutes, in: 5...240, step: 5)
                }
                .listRowBackground(Color.surface)

                Section {
                    Picker("Priority", selection: $tier) {
                        Text("Must-do").tag(PriorityTier.mustDo)
                        Text("Important").tag(PriorityTier.important)
                        Text("Flexible").tag(PriorityTier.flexible)
                    }
                } footer: {
                    Text("Must-do is never dropped. Important is kept whole or dropped as a unit. Flexible yields first when the day is full.")
                }
                .listRowBackground(Color.surface)
            }
            .jeevesFormChrome()
            .navigationTitle(existing == nil ? "Add activity" : "Edit activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let e = existing { name = e.name; minutes = Double(e.durationMinutes); tier = e.tier }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let e = existing {
            e.name = trimmed; e.durationMinutes = Int(minutes); e.tier = tier
        } else {
            context.insert(RoutineActivity(name: trimmed, durationMinutes: Int(minutes), tier: tier, sortOrder: nextSort))
        }
        context.saveOrLog()
        dismiss()
    }
}
