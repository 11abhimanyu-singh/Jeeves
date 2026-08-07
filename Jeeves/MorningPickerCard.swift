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
    @State private var gymOn = false
    @State private var gymTime = Date()
    @State private var loaded = false
    @State private var planned = false

    private var candidates: [MorningPrompt.Candidate] {
        MorningPrompt.candidates(routine: routine, on: day).filter { !binned.contains($0.name) }
    }
    private var state: DailyPlanState? { planStates.first { $0.date == day.startOfDay } }
    private var dayEvents: [DailyEvent] {
        events.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.startMinute < $1.startMinute }
    }

    private var pickedMinutes: Int {
        candidates.filter { ticked.contains($0.name) }.map(\.minutes).reduce(0, +)
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

            ForEach(candidates) { item in row(item) }

            Divider().overlay(Color.textPrimary.opacity(0.08)).padding(.vertical, 10)
            fixedTimes

            HStack {
                Text("\(MorningPrompt.duration(pickedMinutes)) picked")
                    .font(.ui(12, weight: .semibold))
                    .foregroundStyle(pickedMinutes > freeMinutes ? Color.accentDeep : Color.textPrimary)
                Text("of \(MorningPrompt.duration(freeMinutes)) free")
                    .font(.ui(12)).foregroundStyle(Color.textMuted)
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

    private func row(_ item: MorningPrompt.Candidate) -> some View {
        let on = ticked.contains(item.name)
        return HStack(spacing: 9) {
            Button {
                if on { ticked.remove(item.name) } else { ticked.insert(item.name) }
            } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.ui(18)).foregroundStyle(on ? Color.accent : Color.textMuted)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.ui(13))
                    .foregroundStyle(on ? Color.textPrimary : Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.dueToday {
                    Text("not usually today").font(.ui(10.5)).foregroundStyle(Color.textMuted)
                }
            }
            Spacer(minLength: 4)
            Text("\(item.minutes)m").font(.ui(11.5)).foregroundStyle(Color.textMuted)
                .monospacedDigit()

            // Ticking off says "not today"; the bin says "not on this list".
            // It is today's list only — tomorrow the cadence puts it back.
            Button {
                binned.insert(item.name)
                ticked.remove(item.name)
            } label: {
                Image(systemName: "trash").font(.ui(12.5)).foregroundStyle(Color.textMuted)
                    .frame(width: 34, height: 34).contentShape(Rectangle())
                    .accessibilityLabel("Remove \(item.name) from today's list")
            }
            .buttonStyle(.plain)
        }
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
                    .frame(width: 30, height: 34)
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
            ChipScrollRow(labels: Self.gymHours.map { GeneratedBlock.hhmm($0 * 60) },
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
        ticked = Set(MorningPrompt.candidates(routine: routine, on: day)
            .filter(\.dueToday).map(\.name))
        if let state {
            gymOn = state.hasGymToday
            planned = state.plan != nil
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
        s.hasGymToday = gymOn
        s.gymMinute = gymOn ? gymMinute : nil
        context.saveOrLog("morning.confirm")
        planned = true
        onPlan(day)
    }
}
