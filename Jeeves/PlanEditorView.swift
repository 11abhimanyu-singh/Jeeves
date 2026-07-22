//
//  PlanEditorView.swift
//  Jeeves
//
//  Hand-edit a generated plan. Tap a movable block to change its title,
//  location/note, and length; use "Reorder" to drag blocks into a new order.
//  Anchors (gym, events, sleep, peak reading) are locked — never draggable or
//  editable — and everything else re-times around them via PlanEditLogic.
//

import SwiftUI

struct PlanEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let original: GeneratedPlan
    let onSave: (GeneratedPlan) -> Void

    @State private var blocks: [GeneratedBlock] = []
    @State private var editing: EditItem?

    private struct EditItem: Identifiable { let index: Int; var id: Int { index } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(blocks.indices, id: \.self) { i in
                        row(i)
                            .moveDisabled(blocks[i].isAnchor)
                    }
                    .onMove { from, to in
                        blocks.move(fromOffsets: from, toOffset: to)
                        blocks = PlanEditLogic.retime(blocks)
                    }
                    .listRowBackground(Color.surface)
                } footer: {
                    Text("Tap a block to change its title, location, or length. Use Reorder to drag. Anchors (gym, events, sleep) are locked to their times; everything else flows around them.")
                }
            }
            .jeevesFormChrome()
            .navigationTitle("Edit plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { EditButton().tint(Color.accent) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.semibold) }
            }
            .onAppear { if blocks.isEmpty { blocks = original.blocks } }
            .sheet(item: $editing) { item in
                if blocks.indices.contains(item.index) {
                    BlockDetailEditor(block: blocks[item.index]) { updated in
                        blocks[item.index] = updated
                        blocks = PlanEditLogic.retime(blocks)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ i: Int) -> some View {
        let b = blocks[i]
        let content = HStack(spacing: 12) {
            Text(b.startTime)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(b.isAnchor ? Color.accentDeep : Color.textSoft)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.title).font(.serif(15)).foregroundStyle(Color.textPrimary)
                Text("\(b.durationMinutes) min\(b.note.map { " · \($0)" } ?? "")")
                    .font(.system(size: 11.5)).foregroundStyle(Color.textMuted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: b.isAnchor ? "lock.fill" : "chevron.right")
                .font(.system(size: b.isAnchor ? 12 : 13)).foregroundStyle(Color.textMuted)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())

        if b.isAnchor {
            content
        } else {
            Button { editing = EditItem(index: i) } label: { content }.buttonStyle(.plain)
        }
    }

    private func save() {
        let edited = GeneratedPlan(blocks: PlanEditLogic.retime(blocks),
                                   dropped: original.dropped, shrunk: original.shrunk,
                                   summary: original.summary, boundaryTime: original.boundaryTime)
        onSave(edited)
        dismiss()
    }
}

// MARK: - One block's details

struct BlockDetailEditor: View {
    @Environment(\.dismiss) private var dismiss
    let block: GeneratedBlock
    let onSave: (GeneratedBlock) -> Void

    @State private var title = ""
    @State private var note = ""
    @State private var minutes = 30.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                }
                .listRowBackground(Color.surface)

                Section {
                    TextField("Location or note", text: $note, axis: .vertical)
                } footer: {
                    Text("For a commute or event, where you're going. This relabels the block — it doesn't re-route; for a new travel time, edit the event and re-plan.")
                }
                .listRowBackground(Color.surface)

                Section {
                    Stepper("Duration: \(Int(minutes)) min", value: $minutes, in: 5...240, step: 5)
                }
                .listRowBackground(Color.surface)
            }
            .jeevesFormChrome()
            .navigationTitle("Edit block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(block.edited(title: title.trimmingCharacters(in: .whitespaces),
                                            note: note, durationMinutes: Int(minutes)))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                title = block.title
                note = block.note ?? ""
                minutes = Double(block.durationMinutes)
            }
        }
    }
}
