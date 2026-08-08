//
//  MorningPickerCard.swift
//  Jeeves
//
//  The morning offer, in chat.
//
//  You tick what you are actually doing, bin what shouldn't be on the list,
//  confirm anything with a real time — and only then does Jeeves plan. The
//  arranging is still Jeeves's job; choosing is yours. That split is the whole
//  design: the old flow decided both while you slept, and adherence across the
//  last five planned days was 0%, 0%, 0%, 13%, 36%.
//

import SwiftUI
import SwiftData

struct MorningPickerCard: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RoutineActivity.sortOrder) private var routine: [RoutineActivity]
    @Query private var planStates: [DailyPlanState]
    @Query private var events: [DailyEvent]

    let day: Date
    /// Called with the day once the selection is stored, so the caller can run
    /// the same PlanCoordinator path the planner button uses. The card
    /// deliberately does NOT plan: one planning path, and it isn't here.
    var onPlan: (Date) -> Void = { _ in }

    @State private var ticked: Set<String> = []
    @State private var binned: Set<String> = []
    /// Planner name → minutes, for TODAY only. Absent means "use the routine's
    /// own duration", which is why this is a sparse map rather than a copy of
    /// every row's length.
    @State private var minutes: [String: Int] = [:]
    /// The user's order for today, by planner name. Empty until they move
    /// something — the routine's own order is the default shape of a day.
    @State private var order: [String] = []
    /// Editing is a MODE, not extra buttons on every row. Eight controls will
    /// not fit across 402 points at 44pt each, so the row shows the duration
    /// controls by default and swaps them for the arrows and the bin here. Every
    /// target keeps its full width, and the default row keeps its name legible.
    @State private var reordering = false
    @State private var gymOn = false
    @State private var gymTime = Date()
    @State private var loaded = false
    /// Set by THIS card's own button, not by "a plan exists". A card reopened
    /// on an already-planned day must still be usable — re-picking is the
    /// whole point of being able to reopen it.
    @State private var planned = false

    private var candidates: [MorningPrompt.Candidate] {
        let rows = MorningPrompt.candidates(routine: routine, on: day)
            .filter { !binned.contains($0.name) }
        guard !order.isEmpty else { return rows }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return rows.enumerated()
            .sorted { ($0.element.name.rank(rank, $0.offset, order.count))
                    < ($1.element.name.rank(rank, $1.offset, order.count)) }
            .map(\.element)
    }

    /// Move a row one place, and remember the WHOLE order — storing only the
    /// moved name would leave the rest ambiguous the moment the routine changes.
    private func move(_ name: String, by delta: Int) {
        var names = candidates.map(\.name)
        guard let from = names.firstIndex(of: name) else { return }
        let to = from + delta
        guard names.indices.contains(to) else { return }
        names.swapAt(from, to)
        order = names
    }
    private var state: DailyPlanState? { planStates.first { $0.date == day.startOfDay } }
    private var dayEvents: [DailyEvent] {
        events.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.startMinute < $1.startMinute }
    }

    /// What this row will actually run for today.
    private func length(_ item: MorningPrompt.Candidate) -> Int {
        minutes[item.name] ?? item.minutes
    }

    private var pickedMinutes: Int {
        candidates.filter { ticked.contains($0.name) }.map(length).reduce(0, +)
    }

    /// The step, and the floor. 30 minutes is the planner's own minimum block
    /// (PlanRules) — letting the card set 15 would produce a block the packer
    /// would then refuse to schedule, which is a worse answer than not offering
    /// it.
    private static let step = 15
    private static let floorMinutes = 30
    private static let ceilingMinutes = 240

    private func nudge(_ item: MorningPrompt.Candidate, by delta: Int) {
        let next = min(Self.ceilingMinutes, max(Self.floorMinutes, length(item) + delta))
        // Back to the routine's own number = no override, so a row nudged and
        // then nudged back does not persist a value identical to the default.
        if next == item.minutes { minutes.removeValue(forKey: item.name) }
        else { minutes[item.name] = next }
    }
    private var freeMinutes: Int {
        MorningPrompt.freeMinutes(gymAt: gymOn ? gymMinute : nil,
                                  gymSpanMinutes: DayPlanner.gymSpan(Baseline.gymSession(from: routine)).total)
    }
    private var gymMinute: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: gymTime)
        return (c.hour ?? 17) * 60 + (c.minute ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(MorningPrompt.chatOpener(dueCount: candidates.filter(\.dueToday).count,
                                          totalMinutes: pickedMinutes, freeMinutes: freeMinutes))
                .font(.ui(13)).foregroundStyle(Color.textSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 11)

            HStack {
                Spacer()
                // "Edit", not "Reorder": the mode moves rows AND bins them, and
                // a control that deletes must not be hiding behind a word that
                // only promises to rearrange.
                Button { reordering.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: reordering ? "checkmark" : "pencil")
                            .font(.ui(10.5, weight: .bold))
                        Text(reordering ? "Done" : "Edit").font(.ui(11.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentDeep)
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .background(Capsule().fill(Color.accent.opacity(reordering ? 0.2 : 0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reordering ? "Finish editing" : "Reorder or remove activities")
            }
            .padding(.bottom, 6)

            ForEach(candidates) { item in row(item) }

            Divider().overlay(Color.textPrimary.opacity(0.08)).padding(.vertical, 10)
            fixedTimes

            HStack {
                Text("\(MorningPrompt.duration(pickedMinutes)) picked")
                    .font(.ui(12, weight: .semibold))
                    .foregroundStyle(pickedMinutes > freeMinutes ? Color.accentDeep : Color.textPrimary)
                Text("of \(MorningPrompt.duration(freeMinutes)) free")
                    .font(.ui(12)).foregroundStyle(Color.textSoft)
                Spacer()
            }
            .padding(.top, 10)

            Button { confirm() } label: {
                Text(planned ? "Planned" : "Plan my day")
                    .font(.ui(14.5, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(planned ? Color.textMuted.opacity(0.3) : Color.accentDeep))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(planned)
            .padding(.top, 9)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
        .onAppear(perform: load)
    }

    // MARK: rows

    /// One activity, its duration, and the controls that change both.
    ///
    /// tools/visual-judge.py caught "Photography" rendering as "Photograph / y",
    /// a word cut in half. Neither side of that could give way: the targets went
    /// to 44pt to fix a real accessibility finding, and a broken word is not a
    /// layout.
    ///
    /// So the row stops insisting on one line. `ViewThatFits` measures the
    /// single-line arrangement — the name there is `lineLimit(1).fixedSize()`,
    /// so it reports the width it actually wants rather than quietly wrapping —
    /// and when that does not fit, the name takes its own line with the controls
    /// beneath. This also holds at large Dynamic Type, where no fixed column
    /// division could.
    ///
    /// HOW MUCH ROOM THE NAME ACTUALLY GETS, measured rather than guessed — the
    /// first version of this comment claimed ~110pt and was wrong. The card's
    /// content is 342pt wide on the 402pt capture device, and the fixed chrome
    /// is tickBox 44 + three 9pt gaps + a 4pt Spacer + the controls:
    ///
    ///   default (− 34m +)      140pt of controls → 127pt for the name
    ///   editing (↑ ↓ bin)      150pt of controls → 117pt for the name
    ///
    /// With the bin still on every default row the controls were 193pt and the
    /// name got 74pt, so nine of eleven rows stacked — verified against the a11y
    /// frames in evidence/20260808-193634. Moving the bin into the edit mode
    /// bought back 53pt, which is the difference between "Photography" (78pt),
    /// "Chore buffer" (77), "Reading habit" (84) and "Job applications" (100)
    /// fitting on one line and not fitting.
    ///
    /// The four "Interview prep — …" names are 155–194pt and stack in both
    /// modes. Nothing short of truncating them changes that, and a truncated
    /// name in a list you are choosing from is worse than a tall row. That is
    /// why the stacked branch indents its controls under the name rather than
    /// right-aligning them: a row taking the fallback among rows that do not
    /// must still read as one row.
    private func row(_ item: MorningPrompt.Candidate) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                tickBox(item)
                nameColumn(item, wraps: false)
                Spacer(minLength: 4)
                controls(item)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    tickBox(item)
                    nameColumn(item, wraps: true)
                    Spacer(minLength: 4)
                }
                // Indented under the name, NOT pushed to the trailing edge.
                // Right-aligning them left a void where the label should be,
                // and in reorder mode — where the chrome is small enough that
                // every row but the longest stays on one line — that produced a
                // single orphaned pair of arrows floating beside nothing.
                // tools/visual-judge.py filed it as misaligned on "Interview
                // prep — Product Sense" and was right. Sitting directly beneath
                // the name, they read as belonging to it.
                HStack(spacing: 9) {
                    controls(item)
                    Spacer(minLength: 0)
                }
                .padding(.leading, Touch.target + 9)
            }
        }
    }

    private func tickBox(_ item: MorningPrompt.Candidate) -> some View {
        let on = ticked.contains(item.name)
        return Button {
            if on { ticked.remove(item.name) } else { ticked.insert(item.name) }
        } label: {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.ui(18)).foregroundStyle(on ? Color.accent : Color.textMuted)
                .frame(width: Touch.target, height: Touch.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `wraps: false` is the measuring form — it refuses to break, so
    /// `ViewThatFits` can tell that the single-line row is too narrow instead of
    /// being handed a silently wrapped label that "fits".
    @ViewBuilder
    private func nameColumn(_ item: MorningPrompt.Candidate, wraps: Bool) -> some View {
        let on = ticked.contains(item.name)
        VStack(alignment: .leading, spacing: 1) {
            Text(item.name).font(.ui(13))
                .foregroundStyle(on ? Color.textPrimary : Color.textMuted)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: true)
            if !item.dueToday {
                Text("not usually today").font(.ui(10.5)).foregroundStyle(Color.textSoft)
                    .lineLimit(1).fixedSize()
            }
        }
    }

    @ViewBuilder
    private func controls(_ item: MorningPrompt.Candidate) -> some View {
        let on = ticked.contains(item.name)
        HStack(spacing: 9) {
            if reordering {
                let names = candidates.map(\.name)
                let index = names.firstIndex(of: item.name) ?? 0
                stepButton("arrow.up", label: "Move \(item.name) up",
                           enabled: index > 0) { move(item.name, by: -1) }
                stepButton("arrow.down", label: "Move \(item.name) down",
                           enabled: index < names.count - 1) { move(item.name, by: 1) }

                // Ticking off says "not today"; the bin says "not on this list".
                // It is today's list only — tomorrow the cadence puts it back.
                //
                // It lives in the edit mode rather than on every row because the
                // default row could not afford it: four 44pt controls left the
                // name 74pt, so nine of eleven rows stacked. Without the bin the
                // name gets 127pt and most rows are one line again.
                Button {
                    binned.insert(item.name)
                    ticked.remove(item.name)
                } label: {
                    Image(systemName: "trash").font(.ui(12.5)).foregroundStyle(Color.textMuted)
                        .frame(width: Touch.target, height: Touch.target).contentShape(Rectangle())
                        .accessibilityLabel("Remove \(item.name) from today's list")
                }
                .buttonStyle(.plain)
            } else {
                // Buttons, not a Stepper: a Stepper is the same class of control
                // as the Toggle that was completely dead to touch in this card,
                // and this row already proves Buttons work here.
                stepButton("minus", label: "\(item.name): take off 15 minutes",
                           enabled: on && length(item) > Self.floorMinutes) {
                    nudge(item, by: -Self.step)
                }
                Text("\(length(item))m")
                    .font(.ui(11.5, weight: minutes[item.name] == nil ? .regular : .semibold))
                    .foregroundStyle(minutes[item.name] == nil ? Color.textSoft : Color.accentDeep)
                    .monospacedDigit()
                    .frame(minWidth: 34)
                stepButton("plus", label: "\(item.name): add 15 minutes",
                           enabled: on && length(item) < Self.ceilingMinutes) {
                    nudge(item, by: Self.step)
                }
            }
        }
    }

    /// `label` is required rather than derived from the symbol. It used to be
    /// `symbol == "plus" ? "Add 15 minutes" : "Take off 15 minutes"`, so when
    /// the reordering branch reused this helper for the two arrows, both
    /// announced "Take off 15 minutes" — no direction, and a duration claim that
    /// was false for both. A VoiceOver user could not tell the arrows apart.
    private func stepButton(_ symbol: String, label: String,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(11, weight: .bold))
                .foregroundStyle(enabled ? Color.accent : Color.textMuted.opacity(0.35))
                .frame(width: Touch.target, height: Touch.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// The gym hours worth one tap. Anything else is the picker underneath —
    /// but a chip is a Button, and Buttons are the only control in this card
    /// that survived hit-testing, so the common path never depends on the
    /// picker working.
    private static let gymHours = [6, 7, 8, 17, 18, 19, 20]

    @ViewBuilder
    private var fixedTimes: some View {
        Text("ANYTHING WITH A REAL TIME")
            .font(.ui(9.5, weight: .bold)).kerning(0.8).foregroundStyle(Color.textMuted)
            .padding(.bottom, 7)

        // A checkbox, not a switch — matching the rows above it and
        // ActivityPickerSheet's gym row, which is also a Button. A bare
        // `Toggle` here was completely dead to touch while the checkboxes
        // beside it worked; a switch alone is also a 51×31 target in a card
        // where everything else takes the whole row.
        Button { gymOn.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: gymOn ? "checkmark.square.fill" : "square")
                    .font(.ui(18)).foregroundStyle(gymOn ? Color.accent : Color.textMuted)
                    .frame(width: Touch.target, height: Touch.target)
                Text("Gym").font(.ui(13))
                    .foregroundStyle(gymOn ? Color.textPrimary : Color.textMuted)
                Spacer(minLength: 4)
                Text("\(DayPlanner.gymSpan(Baseline.gymSession(from: routine)).total)m")
                    .font(.ui(11.5)).foregroundStyle(Color.textMuted).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if gymOn {
            Text("starts").font(.ui(12)).foregroundStyle(Color.textSoft)
                .padding(.top, 6).padding(.bottom, 4)
            ChipWrapRow(labels: Self.gymHours.map { GeneratedBlock.hhmm($0 * 60) },
                          selected: { gymMinute == Self.gymHours[$0] * 60 },
                          pick: { setGymHour(Self.gymHours[$0]) })
            HStack {
                Text("another time").font(.ui(12)).foregroundStyle(Color.textSoft)
                Spacer()
                DatePicker("", selection: $gymTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            .padding(.top, 6)
        }

        // Events already have their times — they are shown, not asked about.
        ForEach(dayEvents, id: \.id) { e in
            HStack {
                Text(e.title).font(.ui(13)).foregroundStyle(Color.textPrimary).lineLimit(1)
                Spacer()
                Text(GeneratedBlock.hhmm(e.startMinute))
                    .font(.ui(12, weight: .semibold)).foregroundStyle(Color.accentDeep).monospacedDigit()
            }
            .padding(.top, 4)
        }
    }

    // MARK: state

    private func load() {
        guard !loaded else { return }
        loaded = true
        // A day you have already chosen reopens on YOUR choice, not on the
        // cadence's — otherwise "let me adjust one thing" starts by silently
        // undoing everything you unticked an hour ago.
        if case .only(let chosen) = state?.activitySelection {
            ticked = chosen
        } else {
            ticked = Set(MorningPrompt.candidates(routine: routine, on: day)
                .filter(\.dueToday).map(\.name))
        }
        minutes = state?.durationOverrides ?? [:]
        order = state?.activityOrder ?? []
        if let state {
            gymOn = state.hasGymToday
            if let m = state.gymMinute,
               let d = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) {
                gymTime = d
            }
        }
        if !gymOn, let d = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: day) {
            gymTime = d
        }
    }

    private func setGymHour(_ hour: Int) {
        guard let d = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { return }
        gymTime = d
    }

    private func confirm() {
        let s = DailyPlanState.fetchOrCreate(for: day, in: context,
                                             hasGymToday: gymOn, gymMinute: gymOn ? gymMinute : nil)
        // An explicit pick — which outranks the weekday cadence, exactly as the
        // activity picker's does. Binning and unticking both land here as
        // absence, because from the planner's side they mean the same thing:
        // not part of today.
        s.activitySelection = .only(ticked)
        // Only for rows still on the list — a binned row's nudge is meaningless
        // and would otherwise sit in the store forever.
        s.durationOverrides = minutes.filter { ticked.contains($0.key) }
        s.activityOrder = order.filter { ticked.contains($0) }
        s.hasGymToday = gymOn
        s.gymMinute = gymOn ? gymMinute : nil
        context.saveOrLog("morning.confirm")
        planned = true
        onPlan(day)
    }
}

private extension String {
    /// Rank for the per-day order: placed names first in their chosen order,
    /// everything else after, keeping its original relative position.
    func rank(_ order: [String: Int], _ fallbackIndex: Int, _ placed: Int) -> Int {
        order[self] ?? (placed + fallbackIndex)
    }
}
