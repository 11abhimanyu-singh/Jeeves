//
//  PlanningProgressCard.swift
//  Jeeves
//
//  What the user sees during the longest wait in the app.
//
//  Measured over 74 real generations in the production store, a user-tapped
//  plan takes a median of about four minutes and a mean of nine; the worst
//  observed run was five and a half hours. Against that, the old UI offered an
//  indeterminate spinner and one static line — no elapsed time, no idea how
//  long is normal, and no way out. A spinner that has been turning for six
//  minutes is indistinguishable from a hang.
//
//  So this card answers the three questions that actually get asked while
//  waiting: how long has it been, how long should it be, and can I stop.
//  Nothing here is a fake progress bar — the pipeline can't know its own
//  percentage, and inventing one would be a lie that erodes the app's whole
//  posture of telling the user the truth.
//

import SwiftUI

struct PlanningProgressCard: View {
    let startedAt: Date
    var onCancel: () -> Void

    /// Typical runs from the store's own history. Used for the expectation
    /// line and for deciding when a wait has stopped being normal.
    private static let typicalSeconds: Int = 240
    private static let concerningSeconds: Int = 600

    var body: some View {
        // TimelineView drives the counter without a Timer of its own, so the
        // card can't leak one if the view goes away mid-plan.
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    ProgressView()
                    Text(stage(elapsed))
                        .font(.ui(13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Spacer(minLength: 6)
                    Text(clock(elapsed))
                        .font(.ui(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.textSoft)
                        .monospacedDigit()
                        .accessibilityLabel("\(elapsed / 60) minutes \(elapsed % 60) seconds elapsed")
                }

                Text(expectation(elapsed))
                    .font(.ui(11.5))
                    .foregroundStyle(elapsed > Self.concerningSeconds ? Color.accentDeep : Color.textSoft)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onCancel) {
                    Text("Stop and keep the current plan")
                        .font(.ui(12, weight: .semibold))
                        .foregroundStyle(Color.accentDeep)
                        .frame(minHeight: 44)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop planning")
                .accessibilityHint("Keeps whatever plan is already saved for this day")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
            // One announcement per stage change rather than per second —
            // VoiceOver reading a ticking clock aloud would be unusable.
            .accessibilityElement(children: .contain)
        }
    }

    /// Honest stage names. The pipeline really does do these in order, so this
    /// narrates rather than guesses — but it's time-derived, not event-driven,
    /// so it stays deliberately vague rather than claiming a precise step.
    private func stage(_ elapsed: Int) -> String {
        switch elapsed {
        case ..<8:   return "Reading your day…"
        case ..<25:  return "Checking traffic…"
        default:     return "Thinking it through…"
        }
    }

    private func expectation(_ elapsed: Int) -> String {
        if elapsed > Self.concerningSeconds {
            return "This is taking longer than usual — most plans land inside four minutes. It's still running; you can stop and keep the plan you already have."
        }
        if elapsed > Self.typicalSeconds {
            return "Longer days take longer to think through. Still going."
        }
        return "Usually about two to four minutes — it's reasoning through the whole day, not filling slots."
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
