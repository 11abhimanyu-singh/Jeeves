//
//  FlightStatusLine.swift
//  Jeeves
//
//  The one row that survives a missed notification.
//
//  A push happens once, at a moment the phone may be face-down. The journey
//  page is where someone looks when they are actually thinking about the trip,
//  so the status lives there permanently — and carries whether a decision is
//  still outstanding, which is what closes the loop. A line that only said
//  "late by 3h" would leave you wondering whether you'd already dealt with it.
//
//  Every string here comes from a FlightWatchState case. That is deliberate:
//  "on time" cannot be produced by a missing value or an empty branch, only by
//  a fresh reading that actually said so.
//

import SwiftUI

struct FlightStatusLine: View {
    let flightNumber: String
    let state: FlightWatchState
    /// Called when the row is tapped and there is something to decide.
    var onTap: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Group {
            if state.isActionable, let onTap {
                Button(action: onTap) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(state.isActionable ? .isButton : [])
        .accessibilityHint(state.isActionable ? "Opens the leave-by decision" : "")
    }

    private var row: some View {
        HStack(spacing: 7) {
            if showsDot {
                Circle()
                    .fill(dotColour)
                    .frame(width: 7, height: 7)
                    .opacity(pulsing ? 0.35 : 1)
                    .animation(reduceMotion ? nil
                               : .easeInOut(duration: 1).repeatForever(autoreverses: true),
                               value: pulsing)
                    .onAppear { if !reduceMotion { pulsing = true } }
            }

            Text(headline)
                .font(.ui(11.5, weight: .semibold))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            if let trailing {
                Text(trailing)
                    .font(.ui(11.5, weight: .semibold))
                    .foregroundStyle(trailingTint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
    }

    // MARK: Copy

    private var headline: String {
        switch state {
        case .notYetWatching(let from):
            return "Watching \(flightNumber) from \(clock(from))"
        case .onTime:
            return "\(flightNumber) on time"
        case .lateUndecided(let minutes, _), .lateSettled(let minutes, _):
            return "\(flightNumber) late by \(TicketItinerary.durationLabel(minutes))"
        case .stale(let last):
            return last == nil
                ? "No flight update yet"
                : "No flight update since \(clock(last!))"
        case .cancelled:
            return "\(flightNumber) is cancelled"
        }
    }

    /// The tail is where the outstanding decision lives — the reason this
    /// component exists rather than a plain status label.
    private var trailing: String? {
        switch state {
        case .notYetWatching:              return nil
        case .onTime(let at):              return "checked \(ago(at))"
        case .lateUndecided:               return "leave-by not updated ›"
        case .lateSettled(_, let leaveBy): return "leave-by \(clock(leaveBy)) ›"
        case .stale(let last):             return last.map { "\(ago($0)) ›" } ?? nil
        case .cancelled:                   return "what now ›"
        }
    }

    private var spokenLabel: String {
        // VoiceOver reads one sentence, not a row of fragments.
        [headline, trailing?.replacingOccurrences(of: " ›", with: "")]
            .compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Look

    private var showsDot: Bool {
        switch state {
        case .onTime, .lateUndecided, .cancelled: return true
        default: return false
        }
    }

    private var dotColour: Color {
        switch state {
        case .onTime: return Color.sageDeep
        default:      return Color.accentDeep
        }
    }

    private var tint: Color {
        switch state {
        case .lateUndecided, .cancelled: return Color.accentDeep
        case .onTime:                    return Color.sageDeep
        case .notYetWatching:            return Color.textMuted
        case .stale:                     return Color.textSoft
        case .lateSettled:               return Color.textPrimary
        }
    }

    private var trailingTint: Color {
        switch state {
        case .lateUndecided, .cancelled: return Color.accentDeep
        case .onTime:                    return Color.sageDeep
        case .lateSettled:               return Color.textSoft
        default:                         return Color.textMuted
        }
    }

    private var background: some View {
        let fill: Color
        switch state {
        case .lateUndecided, .cancelled: fill = Color(hex: "F3D9C4")
        case .onTime:                    fill = Color.sageLight
        default:                         fill = Color.surfaceDeep
        }
        return Rectangle().fill(fill)
    }

    // MARK: Formatting

    private func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// Relative age, kept coarse — "checked 2 min ago" is useful, "checked
    /// 127 seconds ago" is noise.
    private func ago(_ date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 1  { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60)h ago"
    }
}
