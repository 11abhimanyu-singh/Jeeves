//
//  DayPlannerView.swift
//  Jeeves
//
//  Enter today's weightlifting time (or mark a rest day) and get the full
//  8:00 AM – 8:30 PM schedule, built around the gym-pivot algorithm.
//  Gym time persists across app launches. Tapping a prep/leisure block logs
//  it as done, which is what lets tomorrow's plan actually respond to today.
//

import SwiftUI
import SwiftData

struct DayPlannerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var prepSessions: [PrepSession]
    @Query private var leisureLogs: [LeisureLog]
    @Query private var dailyPlans: [DailyPlanState]

    @State private var hasGymToday = true
    @State private var gymTime: Date = Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var planConfirmed = false

    private var today: Date { Date().startOfDay }

    private var todayPlanState: DailyPlanState? {
        dailyPlans.first { $0.date == today }
    }

    private var gymMinute: Int? {
        guard hasGymToday else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: gymTime)
        return (comps.hour ?? 11) * 60 + (comps.minute ?? 0)
    }

    private var blocks: [PlanBlock] {
        DayPlanner.generate(gymMinute: gymMinute, prepSessions: prepSessions, leisureLogs: leisureLogs)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.textPrimary.opacity(0.14))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if planConfirmed {
                        confirmedSummary
                    } else {
                        gymInput
                    }
                    scheduleList
                }
                .padding(20)
            }
        }
        .background(Color.bg)
        .onAppear { loadGymState() }
        .onChange(of: hasGymToday) { _, _ in saveGymState() }
        .onChange(of: gymTime) { _, _ in saveGymState() }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accent)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "calendar").foregroundStyle(.white).font(.system(size: 13)))
                Text("Day Planner").font(.heading(18)).foregroundStyle(Color.textPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
    }

    private var gymInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle(isOn: $hasGymToday) {
                    Text("Gym today").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Color.textPrimary)
                }
                .tint(Color.accent)

                Button { dismissTile() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.textMuted)
                        .padding(6)
                        .background(Circle().fill(Color.bg))
                }
                .buttonStyle(.plain)
            }

            if hasGymToday {
                HStack {
                    Text("Weightlifting starts").font(.system(size: 13.5)).foregroundStyle(Color.textSoft)
                    Spacer()
                    DatePicker("", selection: $gymTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }

            Button { confirmTile() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                    Text("Set today's plan").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private var confirmedSummary: some View {
        HStack {
            Image(systemName: hasGymToday ? "checkmark.circle.fill" : "moon.zzz.fill")
                .foregroundStyle(Color.sageDeep)
            Text(hasGymToday ? "Gym at \(DayPlanner.label(for: gymMinute ?? 0))" : "Rest day")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Button("Edit") { planConfirmed = false }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.accentDeep)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.sageLight))
    }

    private var scheduleList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TODAY'S PLAN")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.textMuted)

            ForEach(blocks) { block in
                blockRow(block)
            }
        }
    }

    private func blockRow(_ block: PlanBlock) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(DayPlanner.label(for: block.startMinute))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(block.isAnchor ? Color.accentDeep : Color.textSoft)
            }
            .frame(width: 68, alignment: .trailing)

            Rectangle()
                .fill(block.isAnchor ? Color.accent : Color.sage.opacity(0.5))
                .frame(width: 3)
                .cornerRadius(1.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(block.title)
                    .font(.system(size: 14, weight: block.isAnchor ? .bold : .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("\(block.durationMinutes) min")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.textMuted)
                if let note = block.note {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.sageDeep)
                        .padding(.top, 1)
                }
            }
            Spacer()

            if block.isLoggable {
                completionButton(for: block)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: Completion logging

    private func isLogged(_ block: PlanBlock) -> Bool {
        if let cat = block.prepCategory {
            return prepSessions.contains { $0.date == today && $0.category == cat }
        }
        if let activity = block.leisureActivity {
            return leisureLogs.contains { $0.date == today && $0.activity == activity }
        }
        return false
    }

    private func completionButton(for block: PlanBlock) -> some View {
        let done = isLogged(block)
        return Button {
            guard !done else { return }
            logCompletion(for: block)
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(done ? Color.sage : Color.textMuted.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    private func logCompletion(for block: PlanBlock) {
        if let cat = block.prepCategory {
            let session = PrepSession(date: today, category: cat, durationMinutes: Double(block.durationMinutes))
            modelContext.insert(session)
        } else if let activity = block.leisureActivity {
            let log = LeisureLog(date: today, activity: activity, durationMinutes: Double(block.durationMinutes))
            modelContext.insert(log)
        }
        try? modelContext.save()
    }

    // MARK: Tile actions

    private func confirmTile() {
        planConfirmed = true
        saveGymState()
    }

    private func dismissTile() {
        planConfirmed = true
        saveGymState()
    }

    // MARK: Persisted gym state

    private func loadGymState() {
        if let state = todayPlanState {
            hasGymToday = state.hasGymToday
            planConfirmed = state.planConfirmed
            if let minute = state.gymMinute {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour = minute / 60
                comps.minute = minute % 60
                gymTime = Calendar.current.date(from: comps) ?? gymTime
            }
        }
    }

    private func saveGymState() {
        if let state = todayPlanState {
            state.hasGymToday = hasGymToday
            state.gymMinute = gymMinute
            state.planConfirmed = planConfirmed
        } else {
            let state = DailyPlanState(date: today, hasGymToday: hasGymToday, gymMinute: gymMinute, planConfirmed: planConfirmed)
            modelContext.insert(state)
        }
        try? modelContext.save()
    }
}

#Preview {
    DayPlannerView()
        .modelContainer(for: [CheckIn.self, JobApplication.self, PrepSession.self, LeisureLog.self, DailyPlanState.self, Book.self, ReadingLog.self], inMemory: true)
}
