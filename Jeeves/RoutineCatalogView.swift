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

    var body: some View {
        Form {
            Section {
                ForEach(activities) { activity in
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
        .onAppear { Baseline.seed(into: context) }
        .sheet(item: $sheet) { s in
            switch s {
            case .add: RoutineActivityEditor(existing: nil, nextSort: (activities.map(\.sortOrder).max() ?? -1) + 1)
            case .edit(let a): RoutineActivityEditor(existing: a, nextSort: 0)
            }
        }
    }

    private func row(_ a: RoutineActivity) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name.isEmpty ? "Untitled" : a.name)
                    .font(.serif(16))
                    .foregroundStyle(a.enabled ? Color.textPrimary : Color.textMuted)
                Text("\(a.durationMinutes) min · \(a.tier.rawValue)")
                    .font(.system(size: 12.5)).foregroundStyle(Color.textSoft)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { a.enabled },
                set: { a.enabled = $0; try? context.save() }
            ))
            .labelsHidden().tint(Color.accent)
        }
        .padding(.vertical, 2)
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { context.delete(activities[i]) }
        try? context.save()
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        var reordered = activities
        reordered.move(fromOffsets: offsets, toOffset: destination)
        for (i, a) in reordered.enumerated() { a.sortOrder = i }
        try? context.save()
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
        try? context.save()
        dismiss()
    }
}
