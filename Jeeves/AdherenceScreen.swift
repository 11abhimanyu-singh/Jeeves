//
//  AdherenceScreen.swift
//  Jeeves
//
//  What the timing data adds up to — and, just as prominently, what it
//  doesn't cover.
//
//  The last panel is the one most stats screens leave out. It says exactly why
//  the picture is incomplete and links into the backfill window, which is the
//  only thing that gets that window used before it closes.
//

import SwiftUI
import SwiftData

struct AdherenceScreen: View {
    @Environment(\.modelContext) private var context
    @Query private var dailyPlans: [DailyPlanState]
    @Query private var sessions: [ActivitySession]
    @Query private var routine: [RoutineActivity]
    @Query private var checkins: [CheckIn]
    @Query private var prepSessions: [PrepSession]
    @Query private var jobApplications: [JobApplication]
    @Query private var readingLogs: [ReadingLog]
    @Query private var leisureLogs: [LeisureLog]
    @Query private var trips: [Trip]

    @State private var windowDays = 7

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                periodPicker
                hero
                weekStrip
                if !stats.drifts.isEmpty { driftSection }
                if !stats.totals.isEmpty { totalsSection }
                if !stats.gaps.isEmpty { gapsSection }
            }
            .padding(20)
        }
        .background(Color.bg)
        .navigationTitle("Adherence")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: the honest headline

    private var hero: some View {
        VStack(spacing: 4) {
            if let rate = stats.rate {
                Text("\(Int((rate * 100).rounded()))%")
                    .font(.serif(58)).foregroundStyle(Color.textPrimary)
                Text("\(stats.done) of \(stats.assessable) assessable blocks")
                    .font(.ui(13)).foregroundStyle(Color.textSoft)
            } else {
                Text("—").font(.serif(58)).foregroundStyle(Color.textMuted)
                Text("nothing assessable yet")
                    .font(.ui(13)).foregroundStyle(Color.textSoft)
            }
            if stats.unknown > 0 {
                // Outside the fraction, and said out loud. Rolled in as
                // misses, a week where the chain stalled reads as a week you
                // slacked — and the planner would then shrink the very blocks
                // you did do.
                Text("\(stats.unknown) more weren't asked about — not counted either way")
                    .font(.ui(11.5)).italic().foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var periodPicker: some View {
        Picker("", selection: $windowDays) {
            Text("Week").tag(7)
            Text("Month").tag(30)
        }
        .pickerStyle(.segmented)
    }

    // MARK: the strip

    /// Beyond this the column becomes a tower and the strip stops being
    /// scannable — a day with twelve blocks is not twelve times as legible.
    private static let maxMarks = 6

    private var weekStrip: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(stats.days.suffix(windowDays == 7 ? 7 : 14)) { day in
                    VStack(spacing: 5) {
                        Text(Self.letter(day.day))
                            .font(.ui(10.5, weight: .semibold)).foregroundStyle(Color.textMuted)
                        VStack(spacing: 3) {
                            if day.isTravel {
                                mark(Color.accent, filled: true)
                            } else if day.done + day.skipped + day.unknown == 0 {
                                // An empty day still needs a row, or the
                                // columns lose their alignment entirely.
                                Color.clear.frame(width: 9, height: 9)
                            } else {
                                let shown = capped(day)
                                ForEach(0..<shown.done, id: \.self) { _ in mark(Color.sage, filled: true) }
                                ForEach(0..<shown.skipped, id: \.self) { _ in
                                    mark(Color.textPrimary.opacity(0.26), filled: true)
                                }
                                ForEach(0..<shown.unknown, id: \.self) { _ in mark(Color.textMuted, filled: false) }
                                if shown.overflow > 0 {
                                    Text("+\(shown.overflow)")
                                        .font(.ui(8.5, weight: .semibold))
                                        .foregroundStyle(Color.textMuted)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(day.isTravel
                                ? RoundedRectangle(cornerRadius: 9).fill(Color.accent.opacity(0.12))
                                : RoundedRectangle(cornerRadius: 9).fill(Color.clear))
                }
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 11) {
                legend(Color.sage, filled: true, "done")
                legend(Color.textPrimary.opacity(0.26), filled: true, "skipped")
                legend(Color.textMuted, filled: false, "not asked")
                legend(Color.accent, filled: true, "travel")
            }
            .font(.ui(10.5)).foregroundStyle(Color.textMuted)
        }
    }

    /// Marks in proportion, capped. Done first so a good day still reads as
    /// green when it's truncated, and the remainder is counted rather than
    /// silently dropped.
    private func capped(_ day: AdherenceStats.DayRoll)
        -> (done: Int, skipped: Int, unknown: Int, overflow: Int) {
        let total = day.done + day.skipped + day.unknown
        guard total > Self.maxMarks else { return (day.done, day.skipped, day.unknown, 0) }
        let done = min(day.done, Self.maxMarks)
        let skipped = min(day.skipped, Self.maxMarks - done)
        let unknown = min(day.unknown, Self.maxMarks - done - skipped)
        return (done, skipped, unknown, total - done - skipped - unknown)
    }

    /// A hollow mark for "not asked" — visibly different from a skip, because
    /// a blank day and an untracked day mean opposite things.
    private func mark(_ color: Color, filled: Bool) -> some View {
        Group {
            if filled {
                RoundedRectangle(cornerRadius: 2.5).fill(color)
            } else {
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 1.5]))
            }
        }
        .frame(width: 9, height: 9)
    }

    private func legend(_ color: Color, filled: Bool, _ label: String) -> some View {
        HStack(spacing: 4) { mark(color, filled: filled); Text(label) }
    }

    // MARK: where the time actually goes

    private var driftSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHead("Where the time actually goes")
            ForEach(stats.drifts) { drift in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(drift.title).font(.ui(14, weight: .semibold))
                            .foregroundStyle(Color.textPrimary).lineLimit(1)
                        Spacer()
                        Text("\(drift.medianActualMinutes)")
                            .font(.ui(15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.textPrimary)
                        Text("min median").font(.ui(10.5)).foregroundStyle(Color.textMuted)
                    }
                    bars(drift)
                    Text(footnote(for: drift))
                        .font(.ui(11.5)).foregroundStyle(Color.textMuted)
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))

                if drift.isConfident, drift.driftMinutes != 0 {
                    useRealTimes(drift)
                }
            }
        }
    }

    private func bars(_ drift: Drift) -> some View {
        let peak = Double(max(drift.plannedMinutes, drift.medianActualMinutes, 1))
        return VStack(spacing: 3) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.textPrimary.opacity(0.17))
                    .frame(width: geo.size.width * (Double(drift.plannedMinutes) / peak))
            }.frame(height: 6)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accent)
                    .frame(width: geo.size.width * (Double(drift.medianActualMinutes) / peak))
            }.frame(height: 6)
        }
    }

    private func footnote(for drift: Drift) -> String {
        let n = "\(drift.sessions) session\(drift.sessions == 1 ? "" : "s")"
        guard drift.driftMinutes != 0 else { return "planned \(drift.plannedMinutes) · on the nose · \(n)" }
        let word = drift.driftMinutes > 0 ? "over" : "under"
        return "planned \(drift.plannedMinutes) · runs \(abs(drift.driftMinutes)) \(word) · \(n)"
    }

    /// The loop. Without a control like this the whole timing layer is
    /// bookkeeping with a daily compliance cost — this is what makes every
    /// session you log improve tomorrow's plan.
    private func useRealTimes(_ drift: Drift) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plan \(shortName(drift.title)) at **\(drift.medianActualMinutes) min** from now on?")
                .font(.ui(13)).foregroundStyle(Color.textPrimary)
            Button {
                apply(drift)
            } label: {
                Text("Use my real times")
                    .font(.ui(13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 15).frame(minHeight: 36)
                    .background(Capsule().fill(Color.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.accent.opacity(0.13))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accent.opacity(0.34)))
        )
    }

    private func apply(_ drift: Drift) {
        guard let row = routine.first(where: { drift.title.localizedCaseInsensitiveContains($0.name) })
        else { return }
        row.durationMinutes = drift.medianActualMinutes
        context.saveOrLog("adherence.useRealTimes")
        EventLog.log(.toolCall,
                     "routine '\(row.name)' retimed \(drift.plannedMinutes) → \(drift.medianActualMinutes) min from \(drift.sessions) sessions",
                     context: context)
    }

    private func shortName(_ title: String) -> String {
        title.replacingOccurrences(of: "Interview prep — ", with: "")
    }

    // MARK: totals and gaps

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHead("What you got through")
            HStack(spacing: 6) {
                ForEach(stats.totals, id: \.unit) { entry in
                    VStack(spacing: 1) {
                        Text("\(entry.count)")
                            .font(.ui(20, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.textPrimary)
                        Text(entry.unit.short).font(.ui(10)).foregroundStyle(Color.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color.surface))
                }
            }
        }
    }

    private var gapsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHead("What Jeeves doesn't know")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(stats.gaps) { gap in
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(gap.count)")
                            .font(.ui(13, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.textPrimary).frame(minWidth: 14, alignment: .leading)
                        Text(gap.reason).font(.ui(12.5)).foregroundStyle(Color.textSoft)
                    }
                }
                Text("Editable until the end of the next day — after that it's sealed.")
                    .font(.ui(11.5)).italic().foregroundStyle(Color.textMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.textPrimary.opacity(0.26),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
    }

    private func sectionHead(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.ui(11, weight: .semibold)).tracking(0.8)
            .foregroundStyle(Color.textMuted)
    }

    // MARK: data

    private typealias Drift = AdherenceStats.Drift

    private var stats: AdherenceStats {
        let cal = Calendar.current
        let today = Date().startOfDay
        let window = (0..<windowDays).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }.reversed()

        let rolls: [(day: Date, outcomes: [BlockOutcome], isTravel: Bool)] = window.map { day in
            let state = dailyPlans.first { $0.date == day.startOfDay }
            guard let plan = state?.plan else {
                return (day, [], trips.contains { $0.covers(day) })
            }
            let evidence = AdherenceHistory.evidence(
                day: day, checkins: checkins, prep: prepSessions, jobs: jobApplications,
                reading: readingLogs, leisure: leisureLogs, sessions: sessions,
                neverAsked: state?.withheldKeys ?? [])
            let inferred = AdherenceEngine.infer(plan: plan, evidence: evidence,
                                                 cutoffMinute: cal.isDateInToday(day)
                                                    ? Self.minuteOfDay(Date()) : nil)
            let effective = zip(plan.blocks, inferred).map { block, outcome in
                state?.manualOutcomes[AdherenceEngine.key(block)] ?? outcome
            }
            return (day, effective, trips.contains { $0.covers(day) })
        }

        return AdherenceStats.build(days: rolls, sessions: sessions, routine: routine)
    }

    private static func minuteOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private static func letter(_ day: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEEE"
        return f.string(from: day)
    }
}
