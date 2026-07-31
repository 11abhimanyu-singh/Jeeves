//
//  PlanEditorView.swift
//  Jeeves
//
//  Hand-edit a generated plan. Tap any movable block to change its title,
//  location/note, and length (pushes a detail screen — reliable, no nested
//  sheet). Reorder is a separate optional mode behind the ⇅ button so a plain
//  tap always edits and never silently does nothing. Anchors (gym, events,
//  sleep, peak reading) are locked. Everything re-times around them via
//  PlanEditLogic.
//

import SwiftUI

struct PlanEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let original: GeneratedPlan
    let onSave: (GeneratedPlan) -> Void

    @State private var blocks: [GeneratedBlock] = []
    @State private var reordering = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(blocks.indices, id: \.self) { i in
                        rowView(i)
                            .moveDisabled(blocks[i].isAnchor)
                            .listRowBackground(Color.surface)
                    }
                    .onMove { from, to in
                        blocks.move(fromOffsets: from, toOffset: to)
                        blocks = PlanEditLogic.retime(blocks)
                    }
                } footer: {
                    Text(reordering
                         ? "Drag the handles to reorder. Anchors stay locked to their times; everything else flows around them."
                         : "Tap a block to change its title, location, or length. Anchors (gym, events, sleep) are locked. Tap the ⇅ button to reorder.")
                }
            }
            .environment(\.editMode, .constant(reordering ? EditMode.active : EditMode.inactive))
            .jeevesFormChrome()
            .navigationTitle("Edit plan")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Int.self) { i in
                if blocks.indices.contains(i) {
                    BlockDetailEditor(block: blocks[i]) { updated in
                        blocks[i] = updated
                        blocks = PlanEditLogic.retime(blocks)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { reordering.toggle() } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(reordering ? Color.accent : Color.textSoft)
                    }
                    .accessibilityLabel(reordering ? "Done reordering" : "Reorder blocks")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.semibold) }
            }
            .onAppear { if blocks.isEmpty { blocks = original.blocks } }
        }
    }

    @ViewBuilder
    private func rowView(_ i: Int) -> some View {
        let b = blocks[i]
        if b.isAnchor {
            HStack(spacing: 8) {
                rowBody(b)
                Image(systemName: "lock.fill").font(.ui(12)).foregroundStyle(Color.textMuted)
            }
        } else {
            NavigationLink(value: i) { rowBody(b) }
        }
    }

    private func rowBody(_ b: GeneratedBlock) -> some View {
        HStack(spacing: 12) {
            Text(b.startTime)
                .font(.ui(12.5, weight: .semibold))
                .foregroundStyle(b.isAnchor ? Color.accentDeep : Color.textSoft)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.title).font(.serif(15)).foregroundStyle(Color.textPrimary)
                Text("\(b.durationMinutes) min\(b.note.map { " · \($0)" } ?? "")")
                    .font(.ui(11.5)).foregroundStyle(Color.textMuted).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
    }

    private func save() {
        let edited = GeneratedPlan(blocks: PlanEditLogic.retime(blocks),
                                   dropped: original.dropped, shrunk: original.shrunk,
                                   summary: original.summary, boundaryTime: original.boundaryTime)
        onSave(edited)
        dismiss()
    }
}

// MARK: - One block's details (pushed)

struct BlockDetailEditor: View {
    @Environment(\.dismiss) private var dismiss
    let block: GeneratedBlock
    let onSave: (GeneratedBlock) -> Void

    @State private var title = ""
    @State private var note = ""
    @State private var minutes = 30.0

    var body: some View {
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
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(block.edited(title: title.trimmingCharacters(in: .whitespaces),
                                        note: note, durationMinutes: Int(minutes)))
                    dismiss()
                }
                .fontWeight(.semibold)
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
