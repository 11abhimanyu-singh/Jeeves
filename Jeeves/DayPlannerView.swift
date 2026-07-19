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

    // Google Calendar import (reviewed, not silent).
    @State private var calendarReview: CalendarReview?
    @State private var isImportingCalendar = false
    @State private var calendarError: String?

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
        .sheet(item: $calendarReview) { review in
            CalendarImportSheet(review: review, onAdd: addFromCalendar)
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
        // One past day (yesterday) as a ghosted anchor on the left, then today
        // and the next 60 days.
        return (-1...60).compactMap { cal.date(byAdding: .day, value: $0, to: today)?.startOfDay }
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
            // Keep the selected day near the left so exactly one past day peeks
            // in from the left edge as a reference point.
            .onAppear { proxy.scrollTo(selectedDate, anchor: UnitPoint(x: 0.18, y: 0.5)) }
            .onChange(of: selectedDate) { _, d in
                withAnimation { proxy.scrollTo(d, anchor: UnitPoint(x: 0.18, y: 0.5)) }
            }
        }
    }

    /// A weighted timeline dial: the selected day is a full amber circle and
    /// largest; past days are ghosted gray; future days step down in size and
    /// fade out with distance.
    private func datePill(_ date: Date) -> some View {
        let cal = Calendar.current
        let selected = date == selectedDate
        let isPast = date < today
        let distance = cal.dateComponents([.day], from: selectedDate, to: date).day ?? 0
        let hasEvents = events.contains { $0.date == date }

        let opacity: Double = selected ? 1.0 : (isPast ? 0.4 : max(0.42, 1.0 - Double(distance) * 0.11))
        let numberSize: CGFloat = selected ? 20 : (isPast ? 15 : max(15, 19 - CGFloat(max(0, distance - 1))))
        let numberColor: Color = selected ? .white : (isPast ? Color.textMuted : Color.textPrimary)

        return Button { withAnimation { selectedDate = date } } label: {
            VStack(spacing: 6) {
                Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isPast ? Color.textMuted : Color.textSoft)
                ZStack {
                    if selected {
                        Circle().fill(Color.accent).frame(width: 50, height: 50)
                    }
                    Text(date.formatted(.dateTime.day()))
                        .font(.system(size: numberSize, weight: .bold))
                        .foregroundStyle(numberColor)
                }
                .frame(width: 50, height: 50)
                Circle()
                    .fill(hasEvents ? Color.accent : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(width: 52)
            .opacity(opacity)
        }
        .buttonStyle(.plain)
        .id(date)
    }

    // MARK: Events for the selected day

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text(prettyDate(selectedDate))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
                Spacer()
                if KeychainService.isGoogleCalendarConnected {
                    Button { importFromCalendar() } label: {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentDeep)
                    }
                    .buttonStyle(.plain)
                    .disabled(isImportingCalendar)
                }
                Button { addEvent() } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentDeep)
                }
                .buttonStyle(.plain)
            }

            if isImportingCalendar {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading your calendar…").font(.system(size: 12.5)).foregroundStyle(Color.textMuted)
                }
            }
            if let calendarError {
                Text(calendarError).font(.system(size: 12)).foregroundStyle(Color.accentDeep)
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

    // MARK: Google Calendar import (reviewed)

    private func importFromCalendar() {
        isImportingCalendar = true
        calendarError = nil
        let day = selectedDate
        Task {
            defer { isImportingCalendar = false }
            do {
                let evs = try await GoogleCalendarService.events(on: day)
                if evs.isEmpty {
                    calendarError = "No calendar events on \(day == today ? "today" : "this day")."
                } else {
                    calendarReview = CalendarReview(date: day, events: evs)
                }
            } catch {
                calendarError = error.localizedDescription
            }
        }
    }

    /// Adds the user-selected calendar events to the planner, skipping any
    /// that already exist on that day.
    private func addFromCalendar(_ chosen: [CalendarEvent]) {
        for c in chosen {
            let dup = events.contains {
                $0.date == calendarReview?.date && $0.title == c.title && $0.startMinute == c.startMinute
            }
            guard !dup, let day = calendarReview?.date else { continue }
            modelContext.insert(DailyEvent(
                date: day, title: c.title,
                startMinute: c.startMinute, endMinute: c.endMinute,
                destinationAddress: c.location, outboundStart: .home, source: .calendar
            ))
        }
        try? modelContext.save()
        if let day = calendarReview?.date { selectedDate = day }
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(selectedDate.formatted(.dateTime.month(.wide).year()).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.textMuted)
                Text("Day Planner").font(.heading(20)).foregroundStyle(Color.textPrimary)
            }
            Spacer()
            // Tap to jump back to today.
            Button { withAnimation { selectedDate = today } } label: {
                Circle()
                    .fill(Color.surface)
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: "calendar").foregroundStyle(Color.textSoft).font(.system(size: 15)))
            }
            .buttonStyle(.plain)
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

// MARK: - Calendar import review

struct CalendarReview: Identifiable {
    let id = UUID()
    let date: Date
    let events: [CalendarEvent]
}

/// Lists calendar events for a day and lets the user choose which to add —
/// the "ask whether to add" step, instead of a silent import.
private struct CalendarImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let review: CalendarReview
    let onAdd: ([CalendarEvent]) -> Void
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your Google Calendar for \(review.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())). Pick which to add to your planner.")
                        .font(.system(size: 13)).foregroundStyle(Color.textSoft)
                        .padding(.bottom, 4)
                    ForEach(review.events) { event in
                        Button { toggle(event.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(event.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(selected.contains(event.id) ? Color.accent : Color.textMuted.opacity(0.5))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Color.textPrimary)
                                    Text("\(hhmm(event.startMinute))–\(hhmm(event.endMinute))\(event.location.isEmpty ? "" : " · \(event.location)")")
                                        .font(.system(size: 12)).foregroundStyle(Color.textSoft).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Color.bg)
            .navigationTitle("Add from Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selected.count)") {
                        onAdd(review.events.filter { selected.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear { selected = Set(review.events.map(\.id)) } // default: all selected
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
}

#Preview {
    DayPlannerView()
        .modelContainer(for: [CheckIn.self, JobApplication.self, PrepSession.self, LeisureLog.self, DailyPlanState.self, Book.self, ReadingLog.self], inMemory: true)
}
