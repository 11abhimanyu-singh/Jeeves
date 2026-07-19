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
    @Query private var events: [DailyEvent]

    @State private var hasGymToday = true
    @State private var gymTime: Date = Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var planConfirmed = false

    // Date dial: defaults to today, scrollable through the next 60 days.
    @State private var selectedDate: Date = Date().startOfDay
    @State private var eventDraft: EventDraft?
    @State private var editingEvent: DailyEvent?

    private var today: Date { Date().startOfDay }
    private var isToday: Bool { selectedDate == today }

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
            dateDial
            Divider().overlay(Color.textPrimary.opacity(0.14))

            ScrollView { scrollContent.padding(20) }
        }
        .background(Color.bg)
        .sheet(item: $eventDraft) { draft in
            EventEditSheet(draft: draft, onSave: saveEvent, onDelete: eventDeleteAction)
        }
        .onAppear { loadGymState() }
        .onChange(of: hasGymToday) { _, _ in saveGymState() }
        .onChange(of: gymTime) { _, _ in saveGymState() }
    }

    // The gym routine + deterministic timeline are specific to today; future
    // days show their events only.
    @ViewBuilder
    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            eventsSection
            if isToday {
                if planConfirmed {
                    confirmedSummary
                } else {
                    gymInput
                }
                scheduleList
            }
        }
    }

    // MARK: Date dial

    private var dialDates: [Date] {
        let cal = Calendar.current
        return (0..<60).compactMap { cal.date(byAdding: .day, value: $0, to: today)?.startOfDay }
    }

    private var selectedEvents: [DailyEvent] {
        events.filter { $0.date == selectedDate }.sorted { $0.startMinute < $1.startMinute }
    }

    private var dateDial: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dialDates, id: \.self) { date in
                        datePill(date)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo(selectedDate, anchor: .center) }
            .onChange(of: selectedDate) { _, d in
                withAnimation { proxy.scrollTo(d, anchor: .center) }
            }
        }
    }

    private func datePill(_ date: Date) -> some View {
        let selected = date == selectedDate
        let dayIsToday = date == today
        let hasEvents = events.contains { $0.date == date }
        return Button { selectedDate = date } label: {
            VStack(spacing: 3) {
                Text(date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 10.5, weight: .semibold))
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 16, weight: .bold))
                Circle()
                    .fill(hasEvents ? (selected ? Color.white : Color.accent) : .clear)
                    .frame(width: 5, height: 5)
            }
            .foregroundStyle(selected ? .white : Color.textPrimary)
            .frame(width: 46, height: 62)
            .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Color.accent : Color.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(dayIsToday && !selected ? Color.accent : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .id(date)
    }

    // MARK: Events for the selected day

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(prettyDate(selectedDate))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
                Spacer()
                Button { addEvent() } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentDeep)
                }
                .buttonStyle(.plain)
            }

            if selectedEvents.isEmpty {
                Text(isToday ? "No events today." : "No events on this day.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSoft)
                    .padding(.vertical, 4)
            } else {
                ForEach(selectedEvents) { event in
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: DailyEvent) -> some View {
        Button { editEvent(event) } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(hhmm(event.startMinute))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.accentDeep)
                    .frame(width: 52, alignment: .trailing)
                Rectangle().fill(Color.accent).frame(width: 3).cornerRadius(1.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("\(hhmm(event.startMinute))–\(hhmm(event.endMinute)) · from \(event.outboundStart.rawValue)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.textSoft)
                    if !event.destinationAddress.isEmpty {
                        Text(event.destinationAddress)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
        }
        .buttonStyle(.plain)
    }

    // MARK: Event actions

    private func addEvent() {
        editingEvent = nil
        eventDraft = EventDraft(on: selectedDate)
    }

    private func editEvent(_ event: DailyEvent) {
        editingEvent = event
        eventDraft = EventDraft(event: event)
    }

    private func saveEvent(_ draft: EventDraft) {
        if let event = editingEvent {
            event.title = draft.title
            event.date = draft.date.startOfDay
            event.startMinute = draft.startMinute
            event.endMinute = draft.endMinute
            event.destinationAddress = draft.address
            event.outboundStart = draft.outboundStart
        } else {
            modelContext.insert(DailyEvent(
                date: draft.date.startOfDay, title: draft.title,
                startMinute: draft.startMinute, endMinute: draft.endMinute,
                destinationAddress: draft.address, outboundStart: draft.outboundStart,
                source: draft.source
            ))
        }
        try? modelContext.save()
        selectedDate = draft.date.startOfDay   // follow the event to its day
        editingEvent = nil
    }

    private var eventDeleteAction: (() -> Void)? {
        guard editingEvent != nil else { return nil }
        return { deleteEditingEvent() }
    }

    private func deleteEditingEvent() {
        if let event = editingEvent {
            modelContext.delete(event)
            try? modelContext.save()
        }
        editingEvent = nil
    }

    private func prettyDate(_ date: Date) -> String {
        let base = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return date == today ? "TODAY · \(base)" : base.uppercased()
    }

    private func hhmm(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

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
