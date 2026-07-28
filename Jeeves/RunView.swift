//
//  RunView.swift
//  Jeeves
//
//  The couch-to-5K screen. Two modes: a plan overview that shows the week/day
//  you're on and this session's segments (with paces), and a hands-off LIVE RUN
//  that walks the segments one at a time — a countdown per block, total elapsed,
//  a next-block preview, the target pace, and a segment progress bar. A Timer
//  drives the countdown (invalidated on disappear). When a block drops to ≤10s it
//  shows a transition banner and fires the injectable `onTransitionCue` hook once
//  (the seam a caller wires a beep/haptic into; audio comes later). On finish it
//  logs a RunSession with an RPE picker. Which week you're on advances with the
//  number of runs already logged (3 sessions = one week).
//

import SwiftUI
import SwiftData

struct RunView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Transition cue, fired once ~10s before each block ends. Defaults to empty
    /// so the view stands alone; a caller can inject a beep/haptic. Kept as a
    /// stored property, not a closure captured elsewhere.
    var onTransitionCue: () -> Void = {}

    /// Explicit initializer so `onTransitionCue` is injectable from another file —
    /// the synthesized memberwise init would be private (private @State members).
    init(onTransitionCue: @escaping () -> Void = {}) {
        self.onTransitionCue = onTransitionCue
    }

    // MARK: Flow state

    private enum Phase { case plan, running, finished }

    @State private var phase: Phase = .plan

    // The session being run (captured on Start so it's stable if a run is logged
    // mid-week and the "current week" pointer moves).
    @State private var segments: [RunSegment] = []
    @State private var runWeekIndex = 0
    @State private var runDayIndex = 0

    @State private var segmentIndex = 0
    @State private var remaining = 0        // seconds left in the current block
    @State private var elapsedTotal = 0     // seconds actually run this session
    @State private var distanceKmAccum = 0.0 // distance accrued per real second at each block's pace
    @State private var isPaused = false
    @State private var cued = false         // has onCue fired for the current block yet
    @State private var timer: Timer?
    @StateObject private var hr = HeartRateMonitor()
    @ObservedObject private var watchLink = WatchLink.shared
    @State private var runStartedAt = Date()

    // Captured at finish so the summary is stable after the timer state resets.
    @State private var finishedDurationSec = 0
    @State private var finishedDistanceKm = 0.0
    @State private var finishedAvgHR: Int? = nil
    @State private var rpe = 6
    @State private var logged = false

    @Query(sort: \RunSession.date, order: .reverse) private var sessions: [RunSession]

    // MARK: Where in the plan we are (derived from logged runs)

    /// Runs logged so far → position in the 16×3 plan. 3 runs clears a week.
    private var completedCount: Int { sessions.count }
    private var programComplete: Bool { completedCount >= RunProgram.totalWeeks * RunProgram.sessionsPerWeek }
    private var currentWeekIndex: Int {
        min(completedCount / RunProgram.sessionsPerWeek, RunProgram.totalWeeks - 1)
    }
    private var currentDayIndex: Int {
        programComplete ? RunProgram.sessionsPerWeek - 1 : completedCount % RunProgram.sessionsPerWeek
    }
    private var currentWeek: RunWeek { RunProgram.week(currentWeekIndex) }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    switch phase {
                    case .plan:     planScreen
                    case .running:  runningScreen
                    case .finished: finishedScreen
                    }
                }
                .padding(20)
            }
            .background(Color.bg)
            .navigationTitle("Running")
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
        .onDisappear { stopTimer(); hr.stop(); watchLink.stopWorkout() }
    }

    // MARK: - Plan overview

    @ViewBuilder
    private var planScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                eyebrow("COUCH TO 5K")
                Text("Week \(currentWeek.number) · Day \(currentDayIndex + 1)")
                    .font(.serif(28))
                    .foregroundStyle(Color.textPrimary)
                Text(currentWeek.focus)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentDeep)
                Text(programComplete
                     ? "You've finished the 16-week plan — this is the graduation run: 30 minutes, non-stop."
                     : "The goal for week 16 is 30 minutes non-stop. One gentle step at a time.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.textSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            weekProgressRow
            sessionSummaryRow
            segmentPlanCard
            startButton

            if let last = sessions.first {
                Text("Last run · Week \(last.weekIndex + 1) · \(clock(last.durationSec)) · \(oneDp(last.distanceKm)) km · \(relativeDay(last.date))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.textMuted)
                    .padding(.top, 2)
            }
        }
    }

    /// A slim 16-cell strip marking weeks done / current / upcoming.
    private var weekProgressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROGRESS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.textMuted)
            HStack(spacing: 3) {
                ForEach(0..<RunProgram.totalWeeks, id: \.self) { w in
                    Capsule()
                        .fill(weekColor(w))
                        .frame(height: 7)
                        .frame(maxWidth: .infinity)
                }
            }
            Text("Week \(currentWeek.number) of \(RunProgram.totalWeeks) · \(completedCount) runs logged")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private func weekColor(_ w: Int) -> Color {
        if w < currentWeekIndex || (programComplete && w == currentWeekIndex) { return Color.sage }
        if w == currentWeekIndex { return Color.accent }
        return Color.surfaceDeep
    }

    /// Total time / run time / planned distance for this session.
    private var sessionSummaryRow: some View {
        HStack(spacing: 10) {
            summaryTile("Total", clock(currentWeek.totalSeconds))
            summaryTile("Running", clock(currentWeek.runSeconds))
            summaryTile("Distance", "\(oneDp(currentWeek.distanceKm)) km")
        }
    }

    private func summaryTile(_ caption: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.serif(19))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
            Text(caption.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
    }

    /// Every block of the session, in order, with its pace.
    private var segmentPlanCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("THIS SESSION")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.textMuted)
                .padding(.bottom, 10)

            let condensed = condensedPlan(currentWeek.segments)
            ForEach(Array(condensed.enumerated()), id: \.offset) { i, row in
                HStack(spacing: 12) {
                    Image(systemName: row.kind.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(tint(for: row.kind))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.label)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                        Text(pace(row.kmh))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textMuted)
                    }
                    Spacer()
                    Text(row.durationLabel)
                        .font(.serif(15))
                        .foregroundStyle(Color.textSoft)
                        .monospacedDigit()
                }
                .padding(.vertical, 9)

                if i < condensed.count - 1 {
                    Divider().overlay(Color.textPrimary.opacity(0.08))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private var startButton: some View {
        Button {
            start()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Start run")
                    .font(.serif(17))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Capsule().fill(Color.accent))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    // MARK: - Live run

    @ViewBuilder
    private var runningScreen: some View {
        if let seg = currentSegment {
            VStack(spacing: 18) {
                Text("BLOCK \(segmentIndex + 1) OF \(segments.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.accentDeep)
                    .frame(maxWidth: .infinity, alignment: .leading)

                currentBlockCard(seg)
                transitionBanner
                elapsedRow
                segmentStrip
                nextPreview
                controls
            }
        } else {
            // Defensive: an empty session can't run — bounce back to the plan.
            Color.clear.onAppear { phase = .plan }
        }
    }

    private func currentBlockCard(_ seg: RunSegment) -> some View {
        VStack(spacing: 16) {
            // Countdown ring with the remaining seconds centered.
            ZStack {
                Circle()
                    .stroke(Color.surfaceDeep, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: blockProgress)
                    .stroke(tint(for: seg.kind), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: remaining)
                VStack(spacing: 0) {
                    Text(clock(remaining))
                        .font(.serif(46))
                        .foregroundStyle(Color.textPrimary)
                        .monospacedDigit()
                    Text(isPaused ? "paused" : "remaining")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.textMuted)
                }
            }
            .frame(width: 176, height: 176)
            .padding(.top, 4)

            VStack(spacing: 6) {
                Text(seg.kind.display.uppercased())
                    .font(.serif(26))
                    .foregroundStyle(tint(for: seg.kind))
                Text("Hold \(pace(seg.targetKmh))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.textSoft)
            }
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    /// Shown for the last 10 seconds of a block: what's coming, and how soon.
    @ViewBuilder
    private var transitionBanner: some View {
        if remaining <= 10 && !isPaused {
            HStack(spacing: 10) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(nextSegment == nil
                     ? "Finishing in \(remaining)s — ease off"
                     : "\(nextSegment!.kind.display.uppercased()) in \(remaining)s")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accent))
            .transition(.opacity)
        }
    }

    private var elapsedRow: some View {
        HStack {
            timeLabel("Elapsed", clock(elapsedTotal))
            Spacer()
            heartRateLabel
            Spacer()
            timeLabel("Remaining", clock(sessionRemaining))
        }
    }

    /// Live heart rate from HealthKit (Apple Watch / AirPods Pro 3). Shows "—"
    /// until a sample arrives, or if HR isn't being recorded.
    private var heartRateLabel: some View {
        VStack(alignment: .center, spacing: 2) {
            Text("BPM")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Color.textMuted)
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12)).foregroundStyle(Color.accent)
                Text((watchLink.currentBPM ?? hr.currentBPM).map(String.init) ?? "—")
                    .font(.serif(18))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
            }
        }
    }

    private func timeLabel(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Color.textMuted)
            Text(value)
                .font(.serif(18))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
        }
    }

    /// A cell per block, tinted done / now / upcoming (by kind for the current one).
    private var segmentStrip: some View {
        HStack(spacing: 3) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { i, seg in
                Capsule()
                    .fill(stripColor(for: i, kind: seg.kind))
                    .frame(height: 7)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func stripColor(for i: Int, kind: RunSegmentKind) -> Color {
        if i < segmentIndex { return Color.sage }
        if i == segmentIndex { return tint(for: kind) }
        return Color.surfaceDeep
    }

    @ViewBuilder
    private var nextPreview: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text("UP NEXT")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Color.textMuted)
                if let next = nextSegment {
                    Text("\(next.kind.display) · \(clock(next.seconds)) · \(pace(next.targetKmh))")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                } else {
                    Text("Last block — you're almost there")
                        .font(.system(size: 14, weight: .medium))
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
                finish()
            } label: {
                Text("End run")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentDeep)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private func controlLabel(_ title: String, icon: String, filled: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(title).font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(filled ? .white : Color.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(
            Capsule().fill(filled ? Color.accent : Color.surface)
                .overlay(Capsule().strokeBorder(Color.textPrimary.opacity(0.10), lineWidth: filled ? 0 : 1))
        )
    }

    // MARK: - Finished / log

    @ViewBuilder
    private var finishedScreen: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.sageLight).frame(width: 92, height: 92)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.sageDeep)
            }
            .padding(.top, 12)

            VStack(spacing: 6) {
                Text("Run logged")
                    .font(.serif(28))
                    .foregroundStyle(Color.textPrimary)
                Text("Week \(runWeekIndex + 1) · Day \(runDayIndex + 1)")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.textSoft)
            }

            HStack(spacing: 10) {
                statTile("Time", clock(finishedDurationSec))
                statTile("Distance", "\(oneDp(finishedDistanceKm)) km")
            }

            rpeCard

            Button {
                save()
            } label: {
                Text(logged ? "Saved" : "Save run")
                    .font(.serif(17))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(logged ? Color.sage : Color.accent))
            }
            .buttonStyle(.plain)
            .disabled(logged)
            .padding(.top, 2)

            Button {
                stopTimer()
                dismiss()
            } label: {
                Text(logged ? "Done" : "Discard")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentDeep)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    /// Effort picker. Selection is carried by the NUMERAL itself (a big serif
    /// figure and the highlighted cell's own number) so it never relies on colour
    /// alone to read which level is chosen.
    private var rpeCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("HOW HARD DID THAT FEEL")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.textMuted)
                Spacer()
            }

            HStack(spacing: 12) {
                Text("\(rpe)")
                    .font(.serif(40))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .frame(minWidth: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rpeWord(rpe))
                        .font(.serif(18))
                        .foregroundStyle(Color.textPrimary)
                    Text("RPE \(rpe) of 10")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.textMuted)
                }
                Spacer()
            }

            // 1–10 selector. Each cell shows its number; the chosen one is filled
            // AND ringed AND echoed as the big numeral above — three non-colour cues.
            HStack(spacing: 6) {
                ForEach(1...10, id: \.self) { n in
                    Button {
                        rpe = n
                    } label: {
                        Text("\(n)")
                            .font(.system(size: 14, weight: n == rpe ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(n == rpe ? .white : Color.textSoft)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(n == rpe ? Color.accent : Color.surfaceDeep.opacity(0.6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9)
                                            .strokeBorder(Color.accentDeep, lineWidth: n == rpe ? 2 : 0)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private func statTile(_ caption: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.serif(26))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
            Text(caption.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    // MARK: - Derived values

    private var currentSegment: RunSegment? {
        segments.indices.contains(segmentIndex) ? segments[segmentIndex] : nil
    }

    private var nextSegment: RunSegment? {
        let n = segmentIndex + 1
        return segments.indices.contains(n) ? segments[n] : nil
    }

    /// Fraction of the current block still to go (drives the ring).
    private var blockProgress: Double {
        guard let seg = currentSegment, seg.seconds > 0 else { return 0 }
        return Double(remaining) / Double(seg.seconds)
    }

    /// Seconds left across the whole session: this block plus every block after it.
    private var sessionRemaining: Int {
        guard segments.indices.contains(segmentIndex) else { return 0 }
        let future = segments[(segmentIndex + 1)...].reduce(0) { $0 + $1.seconds }
        return remaining + future
    }

    private func tint(for kind: RunSegmentKind) -> Color {
        switch kind {
        case .run:                return Color.accent
        case .walk:               return Color.sage
        case .warmup, .cooldown:  return Color.textSoft
        }
    }

    // MARK: - Flow control

    private func start() {
        let week = currentWeek
        segments = week.segments
        runWeekIndex = week.index
        runDayIndex = currentDayIndex
        guard let first = segments.first else { phase = .plan; return }
        segmentIndex = 0
        remaining = first.seconds
        elapsedTotal = 0
        distanceKmAccum = 0
        cued = false
        isPaused = false
        logged = false
        phase = .running
        runStartedAt = Date()
        startTimer()
        // Begin streaming live heart rate: ask the Watch companion to start its
        // workout (continuous HR), and open the HealthKit reader as a fallback.
        watchLink.startWorkout()
        Task { await hr.requestAuthorization(); hr.start() }
    }

    /// One second of the current block.
    private func tick() {
        guard phase == .running, !isPaused else { return }
        // Fire the transition cue once, 10s out from the switch.
        if !cued && remaining <= 10 {
            onTransitionCue()
            cued = true
        }
        elapsedTotal += 1
        // Accrue distance for the second just run at the CURRENT block's pace, so a
        // skipped block never bills its unrun seconds (keeps duration and distance in sync).
        if let seg = currentSegment { distanceKmAccum += seg.targetKmh / 3600.0 }
        if remaining > 1 {
            remaining -= 1
        } else {
            // Zero it before advancing so a naturally completed block counts in
            // full toward the logged distance (advance overwrites this for the
            // next block, or leaves it 0 when finishing).
            remaining = 0
            advance()
        }
    }

    /// Move to the next block, or finish if this was the last.
    private func advance() {
        let n = segmentIndex + 1
        if segments.indices.contains(n) {
            withAnimation { segmentIndex = n }
            remaining = segments[n].seconds
            cued = false
        } else {
            finish()
        }
    }

    /// Skip the rest of the current block — elapsed time isn't padded.
    private func skipSegment() {
        advance()
    }

    /// Stop the clock and move to the summary. Captures duration/distance now so
    /// the finished screen stays stable; the RunSession is written on Save.
    private func finish() {
        guard phase == .running else { return }
        stopTimer()
        finishedDurationSec = elapsedTotal
        finishedDistanceKm = distanceKmAccum   // accrued per real second — exact on skip or early end
        phase = .finished
        watchLink.stopWorkout()
        // Average the run's heart rate over its interval, then stop streaming.
        let started = runStartedAt
        Task {
            finishedAvgHR = await hr.averageBPM(from: started, to: Date())
            hr.stop()
        }
    }

    /// Write the RunSession. Guarded so a double-tap logs once.
    private func save() {
        guard !logged else { return }
        // Average heart rate from HealthKit (Apple Watch / AirPods Pro 3),
        // computed on finish over the run's interval; nil if none was recorded.
        let session = RunSession(
            date: runStartedAt,   // the run's actual start, not the save moment
            weekIndex: runWeekIndex,
            dayIndex: runDayIndex,
            durationSec: finishedDurationSec,
            distanceKm: finishedDistanceKm,
            avgHeartRate: finishedAvgHR,
            rpe: rpe
        )
        modelContext.insert(session)
        // File the run on the Today feed too: finalize the in-progress card the
        // Watch may have created, or create the day's run Workout outright.
        let cal = Calendar.current
        let live = ((try? modelContext.fetch(FetchDescriptor<Workout>())) ?? [])
            .first { $0.type == .run && $0.state == .live && cal.isDate($0.date, inSameDayAs: runStartedAt) }
        let workout = live ?? Workout(date: runStartedAt, type: .run, state: .done, source: .phone,
                                      title: "Run \u{00B7} Week \(runWeekIndex + 1)")
        workout.date = runStartedAt
        workout.state = .done
        workout.durationMin = finishedDurationSec / 60
        if let hr = finishedAvgHR { workout.avgBPM = hr }
        workout.distanceKm = finishedDistanceKm
        if live == nil { modelContext.insert(workout) }
        session.workoutID = workout.id
        // Only mark the run logged if it actually persisted; otherwise leave
        // logged == false so the guard above lets the user retry the save.
        logged = modelContext.saveOrLog()
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        // .common mode so the countdown keeps firing while the user scrolls the run
        // screen — a .default-mode timer stalls during scroll tracking.
        let t = Timer(timeInterval: 1, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Plan condensing (collapse repeated run/walk pairs for the overview)

    private struct PlanRow {
        var kind: RunSegmentKind
        var label: String
        var durationLabel: String
        var kmh: Double
    }

    /// Collapse consecutive identical blocks into one row ("Run · 2 min × 6") so the
    /// overview reads as a plan, not a wall of segments. Warm-up / cool-down stay single.
    private func condensedPlan(_ segs: [RunSegment]) -> [PlanRow] {
        // Group identical interval blocks across the WHOLE session (run and walk
        // always alternate, so they're never physically adjacent), preserving
        // first-appearance order — so a week reads "Run · 1:00 × 8 / Walk · 1:30 × 7"
        // instead of a wall of one row per interval.
        var groups: [(seg: RunSegment, count: Int)] = []
        for seg in segs {
            if let idx = groups.firstIndex(where: {
                $0.seg.kindRaw == seg.kindRaw && $0.seg.seconds == seg.seconds && $0.seg.targetKmh == seg.targetKmh
            }) {
                groups[idx].count += 1
            } else {
                groups.append((seg, 1))
            }
        }
        return groups.map { g in
            let base = "\(g.seg.kind.display) · \(clock(g.seg.seconds))"
            return PlanRow(
                kind: g.seg.kind,
                label: g.count > 1 ? "\(base) × \(g.count)" : base,
                durationLabel: clock(g.seg.seconds * g.count),
                kmh: g.seg.targetKmh
            )
        }
    }

    // MARK: - Formatting helpers

    private func clock(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func pace(_ kmh: Double) -> String {
        String(format: "%.1f km/h", kmh)
    }

    private func oneDp(_ km: Double) -> String {
        String(format: "%.1f", km)
    }

    private func rpeWord(_ n: Int) -> String {
        switch n {
        case ...2:  return "Very easy"
        case 3, 4:  return "Easy"
        case 5, 6:  return "Moderate"
        case 7, 8:  return "Hard"
        default:    return "Maximal"
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Color.accentDeep)
    }

    private func relativeDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
