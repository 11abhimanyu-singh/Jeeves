//
//  ChatReceiptViews.swift
//  Jeeves
//
//  The visible half of a receipt, plus the two small pieces of chrome the
//  composer needs. Kept out of JeevesChatView so that file stays about the
//  conversation rather than about drawing.
//

import SwiftUI

/// A change, rendered so the old value has nowhere to hide. The layout has a
/// slot for it; an empty slot is visibly wrong, which is the entire point —
/// three eval scenarios failed on a reply that quoted only the new value.
struct ReceiptCard: View {
    let receipt: ChatReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.ui(10, weight: .bold))
                Text(heading)
                    .font(.ui(10, weight: .semibold))
                    .kerning(0.6)
            }
            .foregroundStyle(Color.textMuted)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if !receipt.label.isEmpty {
                    Text(receipt.label)
                        .font(.ui(12.5))
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
                if let was = receipt.was {
                    Text(was)
                        .font(.ui(13.5))
                        .foregroundStyle(Color.textMuted)
                        .strikethrough(true, color: Color.textMuted.opacity(0.7))
                    Text("→")
                        .font(.ui(13.5, weight: .bold))
                        .foregroundStyle(Color.accentDeep)
                }
                Text(receipt.now)
                    .font(.ui(13.5, weight: .semibold))
                    .foregroundStyle(receipt.kind == .deleted ? Color.textMuted : Color.textPrimary)
                    .strikethrough(receipt.kind == .deleted, color: Color.textMuted.opacity(0.7))
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)

            if let caveat = receipt.caveat {
                Divider().overlay(Color.textPrimary.opacity(0.09))
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.ui(10))
                        .padding(.top, 2)
                    Text(caveat).font(.ui(12.5))
                }
                .foregroundStyle(Color.accentDeep)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 13).fill(Color.surface)
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .stroke(Color.textPrimary.opacity(0.10)))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceOver)
    }

    private var heading: String {
        switch receipt.kind {
        case .updated: return "UPDATED"
        case .created: return "ADDED"
        case .deleted: return "REMOVED"
        }
    }
    private var icon: String {
        switch receipt.kind {
        case .updated: return "checkmark"
        case .created: return "plus"
        case .deleted: return "minus"
        }
    }
    /// Read aloud as a sentence — "was X, now Y" — because a strikethrough
    /// carries no meaning to VoiceOver.
    private var voiceOver: String {
        var parts = [heading.lowercased(), receipt.label]
        if let was = receipt.was { parts.append("was \(was), now \(receipt.now)") }
        else { parts.append(receipt.now) }
        if let caveat = receipt.caveat { parts.append(caveat) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Twelve bars that actually move, so a recording which silently failed to
/// start looks different from one that is working.
struct RecordingWave: View {
    @State private var animating = false
    private let bars = 12

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .fill(Color.accentDeep.opacity(0.75))
                    .frame(width: 2.5, height: animating ? heights[i % heights.count] : 4)
                    .animation(
                        .easeInOut(duration: 0.55)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.06),
                        value: animating
                    )
            }
        }
        .frame(height: 20)
        .onAppear { animating = true }
        .accessibilityHidden(true)
    }

    private let heights: [CGFloat] = [7, 13, 18, 11, 16, 8, 15, 19, 10, 14, 6, 17]
}

/// Collects the receipts a single turn produced. A reference type on purpose:
/// the executor closure runs inside an escaping async context, and a value
/// captured there would hand back an empty array.
@MainActor
final class ToolReceiptCollector {
    private var calls: [(tool: String, result: String)] = []

    func add(tool: String, result: String) {
        calls.append((tool, result))
    }

    var receipts: [ChatReceipt] { ChatReceipt.parseAll(calls) }
}
