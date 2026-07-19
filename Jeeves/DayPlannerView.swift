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
    @Query private var locations: [SavedLocation]

    @State private var hasGymToday = true
    @State private var gymTime: Date = Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date()) ?? Date()

    // Date dial: defaults to today, scrollable through the next 60 days.
    @State private var selectedDate: Date = Date().startOfDay
    @State private var eventDraft: EventDraft?
    @State private var editingEvent: DailyEvent?

    // Plan generation (the same PlanCoordinator call the chat uses).
    @State private var isPlanning = false
    @State private var planError: String?

    // Google Calendar import (reviewed, not silent).
    @State private var calendarReview: CalendarReview?
    @State private var isImportingCalendar = false
    @State private var calendarError: String?

    private var today: Date { Date().startOfDay }
    private var isToday: Bool { selectedDate == today }

    private func planState(for date: Date) -> DailyPlanState? {
        dailyPlans.first { $0.date == date.startOfDay }
    }
    private var selectedPlanState: DailyPlanState? { planState(for: selectedDate) }

    private var gymMinute: Int? {
        guard hasGymToday else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: gymTime)
        return (comps.hour ?? 11) * 60 + (comps.minute ?? 0)
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
        .onChange(of: selectedDate) { _, _ in loadGymState() }
        .onChange(of: hasGymToday) { _, _ in saveGymState() }
        .onChange(of: gymTime) { _, _ in saveGymState() }
    }

    @ViewBuilder
    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            eventsSection
            gymCard
            planBar
            planCard
        }
    }

    // MARK: Plan my day (persisted, Claude-first)

    /// The committed plan for the selected day, if one has been generated.
    private var savedPlan: GeneratedPlan? { selectedPlanState?.plan }

    private var planBar: some View {
        VStack(spacing: 8) {
            Button(action: planMyDay) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold))
                    Text(savedPlan == nil ? "Plan my day" : "Re-plan").font(.system(size: 14.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accent))
            }
            .buttonStyle(.plain)
            .disabled(isPlanning)

            if isPlanning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Jeeves is planning your day…").font(.system(size: 12.5)).foregroundStyle(Color.textMuted)
                }
            }
            if let planError {
                Text(planError).font(.system(size: 12)).foregroundStyle(Color.accentDeep)
            }
        }
    }

    @ViewBuilder
    private var planCard: some View {
        if let plan = savedPlan {
            PlanTimelineCard(plan: plan, isOffline: selectedPlanState?.generatedPlanIsOffline ?? false)
        }
    }

    private func planMyDay() {
        planError = nil
        isPlanning = true
        let date = selectedDate
        let dayEvents = selectedEvents
        Task {
            let result = await PlanCoordinator.generate(.init(
                hasGym: hasGymToday,
                gymMinute: gymMinute,
                events: dayEvents,
                locations: locations,
                prepSessions: prepSessions
            ))
            // Commit to this date's plan state so it persists and displays here.
            let state = planState(for: date) ?? {
                let s = DailyPlanState(date: date.startOfDay, hasGymToday: hasGymToday, gymMinute: gymMinute)
                modelContext.insert(s); return s
            }()
            state.storePlan(result.plan, isOffline: result.isOffline)
            try? modelContext.save()
            await NotificationService.reschedule(plan: result.plan, on: date)
            if result.isOffline { planError = "Couldn't reach the planning service — showing an offline plan.\(result.error.map { " (\($0))" } ?? "")" }
            isPlanning = false
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

    // MARK: Gym input (per selected date)

    private var gymCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $hasGymToday) {
                Text(isToday ? "Gym today" : "Gym this day").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Color.textPrimary)
            }
            .tint(Color.accent)

            if hasGymToday {
                HStack {
                    Text("Weightlifting starts").font(.system(size: 13.5)).foregroundStyle(Color.textSoft)
                    Spacer()
                    DatePicker("", selection: $gymTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    // MARK: Persisted gym state (per selected date)

    private func loadGymState() {
        if let state = selectedPlanState {
            hasGymToday = state.hasGymToday
            if let minute = state.gymMinute {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: selectedDate)
                comps.hour = minute / 60
                comps.minute = minute % 60
                gymTime = Calendar.current.date(from: comps) ?? gymTime
            }
        } else {
            hasGymToday = false
        }
    }

    private func saveGymState() {
        if let state = selectedPlanState {
            state.hasGymToday = hasGymToday
            state.gymMinute = gymMinute
        } else {
            modelContext.insert(DailyPlanState(date: selectedDate.startOfDay, hasGymToday: hasGymToday, gymMinute: gymMinute))
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
