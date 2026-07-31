//
//  UndoBanner.swift
//  Jeeves
//
//  The recovery half of a delete.
//
//  To-dos and reminders are deleted from a cramped row — the trash sits beside
//  a complete circle, the row body, a due badge and (on reminders) Snooze, all
//  inside one 14 pt-padded strip. Mis-taps are a matter of when, not if, and
//  the deleted thing is text the user typed.
//
//  Confirming every delete would be the wrong trade for something done this
//  often. Undo is the right one: the action stays instant, and the mistake
//  stays reversible for a few seconds. Nielsen's "user control and freedom"
//  is satisfied by the way back, not by the question first.
//

import SwiftUI

/// A delete that can still be taken back.
struct UndoableDelete: Identifiable {
    let id = UUID()
    let label: String
    let restore: () -> Void
}

struct UndoBanner: View {
    @Binding var pending: UndoableDelete?
    /// How long the way back stays open.
    var seconds: Double = 6

    var body: some View {
        if let item = pending {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.ui(12))
                    .foregroundStyle(Color.textSoft)
                Text(item.label)
                    .font(.ui(12.5))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    item.restore()
                    pending = nil
                } label: {
                    Text("Undo")
                        .font(.ui(12.5, weight: .bold))
                        .foregroundStyle(Color.accentDeep)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Undo delete")
                .accessibilityHint(item.label)
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13).fill(Color.surfaceDeep))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // Keyed to the item's id so a second delete restarts the clock
            // instead of inheriting the first one's remaining time.
            .task(id: item.id) {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                pending = nil
            }
        }
    }
}
