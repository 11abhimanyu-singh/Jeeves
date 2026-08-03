//
//  ActivitySessionViews.swift
//  Jeeves
//
//  The running session, and the sheet that turns it into a count.
//
//  Two decisions carried over from the design that the requirements didn't
//  specify, both about the moment you STOP:
//
//  1. The count is nudged UP AS YOU GO, not recalled at the end. Requirement 3
//     asks for the quantum at stop time — the exact moment you are trying to
//     leave and start the next thing. A tally you tap during the block is
//     already right when you finish.
//  2. The button says "Finish & log", not "Stop", so the count prompt is a
//     promise the label already made rather than a surprise you learn to
//     dismiss.
//

import SwiftUI
import SwiftData

// MARK: - The live session, in the app

struct ActivitySessionBar: View {
    @Environment(\.modelContext) private var context
    @Bindable var session: ActivitySession
    /// The day's plan, so finishing can release whatever the chain was holding
    /// behind this session.
    var plan: GeneratedPlan? = nil
    var onFinished: () -> Void = {}

    @State private var showLog = false

    var body: some View {
        VStack(spacing: 12) {
            Text(session.title)
                .font(.serif(16)).foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)

            // A live clock, so a session that silently failed to start looks
            // different from one that is working.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 3) {
                    Text(Self.clock(session.elapsed()))
                        .font(.ui(42, weight: .semibold).monospacedDigit())
                        .foregroundStyle(overrun ? Color.accentDeep : Color.textPrimary)
                    Text(subtitle)
                        .font(.ui(12.5)).foregroundStyle(Color.textMuted)
                }
            }

            progress

            HStack(spacing: 8) {
                Button {
                    session.state == .paused ? session.resume() : session.pause()
                    context.saveOrLog("activity.pauseToggle")
                } label: {
                    Label(session.state == .paused ? "Resume" : "Pause",
                          systemImage: session.state == .paused ? "play.fill" : "pause.fill")
                        .font(.ui(14.5, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Color.surfaceDeep))
                        .foregroundStyle(Color.textPrimary)
                }
                .buttonStyle(.plain)

                Button { showLog = true } label: {
                    Text(session.unit == nil ? "Finish" : "Finish & log")
                        .font(.ui(14.5, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Color.accentDeep))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            if let unit = session.unit {
                runningTally(unit)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Color.surface)
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accent.opacity(session.state == .paused ? 0.2 : 0.45), lineWidth: 1.5))
        )
        .sheet(isPresented: $showLog) {
            ActivityLogSheet(session: session) {
                // The queue moves the moment this stops — that is the whole
                // chaining rule: stop at 2:15 and the next nudge goes at 2:15.
                if let plan {
                    let day = session.day, ctx = context
                    Task { await ActivityTimekeeper.releaseChain(plan: plan, on: day, context: ctx) }
                }
                onFinished()
            }
        }
    }

    private var overrun: Bool {
        session.plannedMinutes > 0 && session.actualMinutes > session.plannedMinutes
    }
    private var subtitle: String {
        if session.state == .paused { return "Paused · \(session.plannedMinutes) min planned" }
        guard session.plannedMinutes > 0 else { return "Running" }
        let left = session.plannedMinutes - session.actualMinutes
        return left >= 0 ? "of \(session.plannedMinutes) min · \(left) left"
                         : "\(-left) min over \(session.plannedMinutes) planned"
    }

    private var progress: some View {
        GeometryReader { geo in
            let fraction = session.plannedMinutes > 0
                ? min(1, Double(session.actualMinutes) / Double(session.plannedMinutes)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.textPrimary.opacity(0.1))
                Capsule()
                    .fill(overrun ? Color.accentDeep : Color.accent)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 5)
    }

    /// Counting during, not after.
    ///
    /// The controls are LEFT-aligned on purpose. Right-aligned, the "+" landed
    /// underneath the floating Jeeves bubble, which is drawn above this view —
    /// the taps did nothing and the count silently stayed at zero. The bubble
    /// owns the bottom-right corner of every screen, so nothing interactive
    /// goes there.
    private func runningTally(_ unit: ActivityUnit) -> some View {
        HStack(spacing: 10) {
            Button {
                session.record(quantity: max(0, session.quantity - 1))
                context.saveOrLog("activity.tally")
            } label: { tallyGlyph("minus") }
            .buttonStyle(.plain)
            Text("\(session.quantity)")
                .font(.ui(19, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.textPrimary)
                .frame(minWidth: 28)
            Button {
                session.record(quantity: session.quantity + 1)
                context.saveOrLog("activity.tally")
            } label: { tallyGlyph("plus") }
            .buttonStyle(.plain)
            Text(unit.label).font(.ui(12.5)).foregroundStyle(Color.textMuted)
                .lineLimit(1).minimumScaleFactor(0.85)
            // Keeps the row clear of the bubble's corner.
            Spacer(minLength: 64)
        }
        .padding(.top, 2)
    }

    private func tallyGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.ui(15, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.bg))
            .contentShape(Rectangle())
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Finish & log

struct ActivityLogSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: ActivitySession
    var onDone: () -> Void = {}

    @State private var count: Int = 0

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Color.textPrimary.opacity(0.22))
                .frame(width: 36, height: 4.5).padding(.top, 8)

            Text("\(session.title) · \(session.actualMinutes) min")
                .font(.serif(17)).foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
            Text(summary).font(.ui(12.5)).foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)

            if let unit = session.unit {
                HStack(spacing: 16) {
                    stepper("minus") { count = max(0, count - 1) }
                    Text("\(count)")
                        .font(.ui(38, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.textPrimary)
                        .frame(minWidth: 74)
                    stepper("plus") { count += 1 }
                }
                Text(unit.label).font(.ui(12.5)).foregroundStyle(Color.textMuted)

                // Chips, not a keyboard — this is the moment you want to leave.
                HStack(spacing: 7) {
                    ForEach(unit.quickPicks, id: \.self) { n in
                        Button { count = n } label: {
                            Text("\(n)")
                                .font(.ui(13, weight: count == n ? .semibold : .regular))
                                .foregroundStyle(count == n ? .white : Color.textPrimary)
                                .padding(.horizontal, 14).frame(minHeight: 34)
                                .background(Capsule().fill(count == n ? Color.accent : Color.surface))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                ActivityTracker.finish(session, quantity: session.unit == nil ? nil : count,
                                       context: context)
                onDone(); dismiss()
            } label: {
                Text("Save").font(.ui(15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color.accent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            HStack(spacing: 18) {
                // Keeps the time, defers the count. On a busy day this is the
                // main path, not a fallback.
                Button("Log later") {
                    ActivityTracker.finish(session, quantity: nil, context: context)
                    onDone(); dismiss()
                }
                Text("·").foregroundStyle(Color.textMuted)
                Button("Didn't happen") {
                    session.cancel()
                    context.saveOrLog("activity.cancel")
                    onDone(); dismiss()
                }
            }
            .font(.ui(13.5)).foregroundStyle(Color.textMuted)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
        .background(Color.bg)
        .presentationDetents([.height(session.unit == nil ? 260 : 420)])
        .onAppear { count = session.quantity }   // pre-filled from the running tally
    }

    private var summary: String {
        var parts = ["planned \(session.plannedMinutes) min"]
        if let drift = session.driftMinutes, drift != 0 {
            parts.append(drift > 0 ? "ran \(drift) over" : "\(-drift) under")
        }
        if session.pausedSeconds > 60 {
            parts.append("paused \(Int(session.pausedSeconds / 60)) min")
        }
        return parts.joined(separator: " · ")
    }

    private func stepper(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.ui(20))
                .foregroundStyle(Color.textPrimary)
                .frame(width: 46, height: 46)
                .background(Circle().stroke(Color.textPrimary.opacity(0.22), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
