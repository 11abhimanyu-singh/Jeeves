//
//  PlanEditorView.swift
//  Jeeves
//
//  Hand-edit a generated plan: drag movable blocks into a new order and change
//  their lengths with a stepper. Anchors (gym, events, sleep, peak reading) are
//  locked — shown with a lock, never draggable — and everything else re-times
//  around them live via PlanEditLogic.
//

import SwiftUI

struct PlanEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let original: GeneratedPlan
    let onSave: (GeneratedPlan) -> Void

    @State private var blocks: [GeneratedBlock] = []

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
                    Text("Drag to reorder. Anchors (gym, events, sleep) are locked to their times; everything else flows around them. Use +/– to change a block's length.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .jeevesFormChrome()
            .navigationTitle("Edit plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save() }.fontWeight(.semibold) }
            }
            .onAppear { if blocks.isEmpty { blocks = original.blocks } }
        }
    }

    private func row(_ i: Int) -> some View {
        let b = blocks[i]
        return HStack(spacing: 12) {
            Text(b.startTime)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(b.isAnchor ? Color.accentDeep : Color.textSoft)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.title).font(.serif(15)).foregroundStyle(Color.textPrimary)
                Text("\(b.durationMinutes) min").font(.system(size: 11.5)).foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 4)
            if b.isAnchor {
                Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(Color.textMuted)
            } else {
                Stepper("", value: durationBinding(i), in: 5...240, step: 5).labelsHidden()
            }
        }
        .padding(.vertical, 2)
    }

    private func durationBinding(_ i: Int) -> Binding<Int> {
        Binding(
            get: { blocks.indices.contains(i) ? blocks[i].durationMinutes : 0 },
            set: { newDuration in
                guard blocks.indices.contains(i) else { return }
                blocks[i] = blocks[i].withDuration(newDuration)
                blocks = PlanEditLogic.retime(blocks)
            }
        )
    }

    private func save() {
        let edited = GeneratedPlan(blocks: PlanEditLogic.retime(blocks),
                                   dropped: original.dropped, shrunk: original.shrunk,
                                   summary: original.summary, boundaryTime: original.boundaryTime)
        onSave(edited)
        dismiss()
    }
}
