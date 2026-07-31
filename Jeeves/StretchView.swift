//
//  StretchView.swift
//  Jeeves
//
//  The guided stretching / mobility flow. Pick a routine, then run it hands-off:
//  one move at a time with a hold countdown, a per-side note where it matters,
//  a next-move preview, a segment progress strip, and the full move list marked
//  done / now / upcoming. A Timer drives the countdown (invalidated on disappear)
//  and fires the `onCue` hook 5 seconds before each switch — the seam a caller
//  can wire a beep or haptic into. On finish it writes a StretchLog.
//

import SwiftUI
import SwiftData

struct StretchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Transition cue, fired ~5s before each hold ends ("beeps 5s before each
    /// switch"). Defaults to empty so the view stands alone; a caller can inject
    /// a beep/haptic. Kept as a stored property, not a closure captured elsewhere.
    var onCue: () -> Void = {}

    /// Explicit initializer so `onCue` is injectable from another file — the
    /// synthesized memberwise init would be private (private @State members).
    init(onCue: @escaping () -> Void = {}) {
        self.onCue = onCue
    }

    // MARK: Flow state

    private enum Phase { case setup, running, finished }

    @State private var phase: Phase = .setup
    @State private var selectedRoutine: StretchRoutine = .coolDown

    // Expanded timeline: per-side moves become two segments (left, then right).
    @State private var segments: [Segment] = []
    @State private var segmentIndex = 0
    @State private var remaining = 0        // seconds left in the current hold
    @State private var elapsedTotal = 0     // seconds actually stretched this session
    @State private var isPaused = false
    @State private var cued = false         // has onCue fired for the current segment yet
    @State private var timer: Timer?

    @Query(sort: \StretchLog.date, order: .reverse) private var logs: [StretchLog]

    // MARK: Segment model

    private enum Side { case left, right }

    /// One timed step of the running flow.
    private struct Segment: Identifiable {
        let id = UUID()
        let moveIndex: Int      // which routine move this belongs to
        let move: StretchMove
        let side: Side?         // nil = whole-body move, else which side

        var holdSeconds: Int { move.holdSeconds }
        var sideNote: String? {
            switch side {
            case .left:  return "Left side"
            case .right: return "Right side"
            case .none:  return nil
            }
        }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    switch phase {
                    case .setup:    setupScreen
                    case .running:  runningScreen
                    case .finished: finishedScreen
                    }
                }
                .padding(20)
            }
            .background(Color.bg)
            .navigationTitle("Stretch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(phase == .running ? "Close" : "Done") {
                        stopTimer()
                        dismiss()
                    }
                    .tint(Color.accentDeep)
                }
            }
        }
        .onDisappear { stopTimer() }
    }

    // MARK: - Setup screen

    @ViewBuilder
    private var setupScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                eyebrow("GUIDED MOBILITY")
                Text("Pick a routine")
                    .font(.serif(28))
                    .foregroundStyle(Color.textPrimary)
                Text("A timed, hands-off flow — hold, breathe, switch on the cue.")
                    .font(.ui(14))
                    .foregroundStyle(Color.textSoft)
            }

            VStack(spacing: 12) {
                ForEach(StretchRoutine.all) { routine in
                    routineCard(routine)
                }
            }

            beginButton

            if let last = logs.first {
                Text("Last session · \(last.routineName) · \(relativeDay(last.date))")
                    .font(.ui(12.5))
                    .foregroundStyle(Color.textMuted)
                    .padding(.top, 2)
            }
        }
    }

    private func routineCard(_ routine: StretchRoutine) -> some View {
        let selected = routine.id == selectedRoutine.id
        return Button {
            selectedRoutine = routine
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(routine.name)
                        .font(.serif(19))
                        .foregroundStyle(Color.textPrimary)
                    Text(routine.subtitle)
                        .font(.ui(13))
                        .foregroundStyle(Color.textSoft)
                        .multilineTextAlignment(.leading)
                    Text("~\(routine.approxMinutes) min · \(routine.moves.count) moves")
                        .font(.ui(12, weight: .medium))
                        .foregroundStyle(Color.accentDeep)
                        .padding(.top, 2)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.ui(22))
                    .foregroundStyle(selected ? Color.accent : Color.textMuted.opacity(0.5))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.accent, lineWidth: selected ? 2 : 0)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var beginButton: some View {
        Button {
            begin()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Begin \(selectedRoutine.name)")
                    .font(.serif(17))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Capsule().fill(Color.accent))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: - Running screen

    @ViewBuilder
    private var runningScreen: some View {
        if let seg = currentSegment {
            VStack(spacing: 18) {
                Text("MOVE \(segmentIndex + 1) OF \(segments.count)")
                    .font(.ui(12, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.accentDeep)
                    .frame(maxWidth: .infinity, alignment: .leading)

                currentMoveCard(seg)
                elapsedRow
                segmentStrip
                nextPreview
                controls
                moveList
            }
        } else {
            // Defensive: an empty routine can't run — bounce back to setup.
            Color.clear.onAppear { phase = .setup }
        }
    }

    private func currentMoveCard(_ seg: Segment) -> some View {
        VStack(spacing: 16) {
            // Countdown ring with the remaining seconds centered.
            ZStack {
                Circle()
                    .stroke(Color.surfaceDeep, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: holdProgress)
                    .stroke(Color.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: remaining)
                VStack(spacing: 0) {
                    Text("\(remaining)")
                        .font(.serif(52))
                        .foregroundStyle(Color.textPrimary)
                        .monospacedDigit()
                    Text(isPaused ? "paused" : "seconds")
                        .font(.ui(12, weight: .medium))
                        .foregroundStyle(Color.textMuted)
                }
            }
            .frame(width: 172, height: 172)
            .padding(.top, 4)

            VStack(spacing: 6) {
                Text(seg.move.name)
                    .font(.serif(24))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                Text(seg.move.target)
                    .font(.ui(14))
                    .foregroundStyle(Color.textSoft)
                if let note = seg.sideNote {
                    Text(note)
                        .font(.ui(12.5, weight: .semibold))
                        .foregroundStyle(Color.accentDeep)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.sageLight))
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private var elapsedRow: some View {
        HStack {
            label("Elapsed", clock(elapsedTotal))
            Spacer()
            label("Remaining", clock(sessionRemaining))
        }
    }

    private func label(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption.uppercased())
                .font(.ui(10.5, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Color.textMuted)
            Text(value)
                .font(.serif(18))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
        }
    }

    /// Thin capsule per segment: done / now / upcoming.
    private var segmentStrip: some View {
        HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { i, _ in
                Capsule()
                    .fill(stripColor(for: i))
                    .frame(height: 6)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func stripColor(for i: Int) -> Color {
        if i < segmentIndex { return Color.sage }
        if i == segmentIndex { return Color.accent }
        return Color.surfaceDeep
    }

    @ViewBuilder
    private var nextPreview: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.down.right")
                .font(.ui(14, weight: .semibold))
                .foregroundStyle(Color.accentDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text("UP NEXT")
                    .font(.ui(10.5, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Color.textMuted)
                if let next = nextSegment {
                    Text(next.sideNote == nil
                         ? next.move.name
                         : "\(next.move.name) · \(next.sideNote!)")
                        .font(.ui(14, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                } else {
                    Text("Last hold — you're almost done")
                        .font(.ui(14, weight: .medium))
                        .foregroundStyle(Color.textSoft)
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface.opacity(0.6)))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    isPaused.toggle()
                } label: {
                    controlLabel(isPaused ? "Resume" : "Pause",
                                 icon: isPaused ? "play.fill" : "pause.fill",
                                 filled: isPaused)
                }
                .buttonStyle(.plain)

                Button {
                    skipSegment()
                } label: {
                    controlLabel("Skip", icon: "forward.fill", filled: false)
                }
                .buttonStyle(.plain)
            }

            Button {
                finish(completed: false)
            } label: {
                Text("End session")
                    .font(.ui(13, weight: .medium))
                    .foregroundStyle(Color.accentDeep)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private func controlLabel(_ title: String, icon: String, filled: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(title).font(.ui(15, weight: .semibold))
        }
        .foregroundStyle(filled ? .white : Color.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(
            Capsule().fill(filled ? Color.accent : Color.surface)
                .overlay(Capsule().strokeBorder(Color.textPrimary.opacity(0.10), lineWidth: filled ? 0 : 1))
        )
    }

    /// The full routine, each move flagged by state.
    private var moveList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ROUTINE")
                .font(.ui(11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.textMuted)
                .padding(.bottom, 8)

            ForEach(Array(selectedRoutine.moves.enumerated()), id: \.element.id) { i, move in
                let state = moveState(i)
                HStack(spacing: 12) {
                    Image(systemName: state.icon)
                        .font(.ui(17))
                        .foregroundStyle(state.tint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(move.name)
                            .font(.ui(15, weight: state == .now ? .semibold : .regular))
                            .foregroundStyle(state == .upcoming ? Color.textSoft : Color.textPrimary)
                        Text(holdSummary(move))
                            .font(.ui(12))
                            .foregroundStyle(Color.textMuted)
                    }
                    Spacer()
                    if state == .now {
                        Text("NOW")
                            .font(.ui(10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Color.accentDeep)
                    }
                }
                .padding(.vertical, 9)

                if i < selectedRoutine.moves.count - 1 {
                    Divider().overlay(Color.textPrimary.opacity(0.08))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    // MARK: - Finished screen

    @ViewBuilder
    private var finishedScreen: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.sageLight).frame(width: 92, height: 92)
                Image(systemName: "checkmark")
                    .font(.ui(40, weight: .semibold))
                    .foregroundStyle(Color.sageDeep)
            }
            .padding(.top, 12)

            VStack(spacing: 6) {
                Text("Nicely done")
                    .font(.serif(28))
                    .foregroundStyle(Color.textPrimary)
                Text(selectedRoutine.name)
                    .font(.ui(15))
                    .foregroundStyle(Color.textSoft)
            }

            HStack(spacing: 12) {
                statTile("Time", clock(elapsedTotal))
                statTile("Moves", "\(selectedRoutine.moves.count)")
            }

            Button {
                begin()
            } label: {
                Text("Go again")
                    .font(.serif(17))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(Color.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Button {
                phase = .setup
            } label: {
                Text("Choose another routine")
                    .font(.ui(14, weight: .medium))
                    .foregroundStyle(Color.accentDeep)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private func statTile(_ caption: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.serif(26))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
            Text(caption.uppercased())
                .font(.ui(10.5, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    // MARK: - Derived values

    private var currentSegment: Segment? {
        segments.indices.contains(segmentIndex) ? segments[segmentIndex] : nil
    }

    private var nextSegment: Segment? {
        let n = segmentIndex + 1
        return segments.indices.contains(n) ? segments[n] : nil
    }

    /// Fraction of the current hold still to go (drives the ring).
    private var holdProgress: Double {
        guard let seg = currentSegment, seg.holdSeconds > 0 else { return 0 }
        return Double(remaining) / Double(seg.holdSeconds)
    }

    /// Seconds left across the whole session: this hold plus every hold after it.
    private var sessionRemaining: Int {
        guard segments.indices.contains(segmentIndex) else { return 0 }
        let future = segments[(segmentIndex + 1)...].reduce(0) { $0 + $1.holdSeconds }
        return remaining + future
    }

    private enum MoveState {
        case done, now, upcoming
        var icon: String {
            switch self {
            case .done:     return "checkmark.circle.fill"
            case .now:      return "circle.circle.fill"
            case .upcoming: return "circle"
            }
        }
        var tint: Color {
            switch self {
            case .done:     return Color.sageDeep
            case .now:      return Color.accent
            case .upcoming: return Color.textMuted.opacity(0.5)
            }
        }
    }

    private func moveState(_ moveIndex: Int) -> MoveState {
        guard let seg = currentSegment else { return .upcoming }
        if moveIndex < seg.moveIndex { return .done }
        if moveIndex == seg.moveIndex { return .now }
        return .upcoming
    }

    // MARK: - Flow control

    private func begin() {
        segments = buildSegments(selectedRoutine)
        guard let first = segments.first else { phase = .setup; return }
        segmentIndex = 0
        remaining = first.holdSeconds
        elapsedTotal = 0
        cued = false
        isPaused = false
        phase = .running
        startTimer()
    }

    /// Expand per-side moves into left-then-right segments.
    private func buildSegments(_ routine: StretchRoutine) -> [Segment] {
        var result: [Segment] = []
        for (i, move) in routine.moves.enumerated() {
            if move.perSide {
                result.append(Segment(moveIndex: i, move: move, side: .left))
                result.append(Segment(moveIndex: i, move: move, side: .right))
            } else {
                result.append(Segment(moveIndex: i, move: move, side: nil))
            }
        }
        return result
    }

    /// One second of the current hold.
    private func tick() {
        guard phase == .running, !isPaused else { return }
        // Fire the transition cue once, 5s out from the switch.
        if !cued && remaining <= 5 {
            onCue()
            cued = true
        }
        elapsedTotal += 1
        if remaining > 1 {
            remaining -= 1
        } else {
            advance()
        }
    }

    /// Move to the next segment, or finish if this was the last.
    private func advance() {
        let n = segmentIndex + 1
        if segments.indices.contains(n) {
            segmentIndex = n
            remaining = segments[n].holdSeconds
            cued = false
        } else {
            finish(completed: true)
        }
    }

    /// Skip the rest of the current hold — no elapsed time is padded.
    private func skipSegment() {
        advance()
    }

    /// Stop, log the session, and show the summary. Guarded so it logs once.
    private func finish(completed: Bool) {
        guard phase == .running else { return }
        stopTimer()
        phase = .finished
        // Only bother logging a session with real work in it.
        if elapsedTotal >= 10 {
            let log = StretchLog(date: Date(), routineName: selectedRoutine.name, durationSec: elapsedTotal)
            modelContext.insert(log)
            modelContext.saveOrLog()
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        // .common mode so the hold countdown + 5s transition cue keep firing while
        // the user scrolls — a .default-mode timer stalls during scroll tracking.
        let t = Timer(timeInterval: 1, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // The transition cue is the whole point of the guided flow; it can't
        // fire usefully behind a lock screen.
        ScreenAwake.acquire()
    }

    private func stopTimer() {
        guard timer != nil else { return }   // keep acquire/release balanced
        timer?.invalidate()
        timer = nil
        ScreenAwake.release()
    }

    // MARK: - Formatting helpers

    private func clock(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func holdSummary(_ move: StretchMove) -> String {
        if move.perSide {
            return "\(move.holdSeconds)s each side · \(move.target)"
        }
        return "\(move.holdSeconds)s · \(move.target)"
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.ui(12, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Color.accentDeep)
    }

    private func relativeDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
