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
    @Query private var routineActivities: [RoutineActivity]
    @Query private var checkins: [CheckIn]
    @Query private var jobApplications: [JobApplication]
    @Query private var readingLogs: [ReadingLog]
    @Query private var trips: [Trip]
    @Query private var allTravelSegments: [TravelSegment]

    @State private var hasGymToday = true
    @State private var gymTime: Date = Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date()) ?? Date()

    // Date dial: defaults to today, scrollable through the next 60 days.
    @State private var selectedDate: Date = Date().startOfDay
    @State private var editingTrip: Trip?
    /// Venue → measured one-way journey minutes. Absent means unmeasured, and
    /// unmeasured is never treated as "far".
    @State private var measuredJourneys: [String: Int] = [:]
    @State private var dismissedTravelDays: Set<Date> = []
    @State private var eventDraft: EventDraft?

    // Plan generation (the same PlanCoordinator call the chat uses).
    @State private var isPlanning = false
    @State private var planError: String?
    @State private var replanNote: String? = nil

    // Google Calendar import (reviewed, not silent).
    @State private var calendarReview: CalendarReview?
    @State private var isImportingCalendar = false
    @State private var calendarError: String?
    @State private var showPlanEditor = false

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
            // Deletability comes from the draft itself — a separate @State
            // raced the sheet's snapshot and the button sometimes vanished.
            EventEditSheet(draft: draft, onSave: saveEvent,
                           onDelete: draft.existingEvent.map { event in { delete(event: event) } })
        }
        .sheet(item: $calendarReview) { review in
            CalendarImportSheet(review: review, onAdd: addFromCalendar)
        }
        .sheet(isPresented: $showPlanEditor) {
            if let plan = savedPlan {
                PlanEditorView(original: plan, onSave: commitEditedPlan)
            }
        }
        .sheet(item: $editingTrip) { TripEditorView(trip: $0) }
        .onAppear { loadGymState(); measureJourneys() }
        .onChange(of: selectedDate) { _, _ in loadGymState(); measureJourneys() }
        .onChange(of: events.count) { _, _ in measureJourneys() }
        .onChange(of: hasGymToday) { _, _ in saveGymState() }
        .onChange(of: gymTime) { _, _ in saveGymState() }
    }

    @ViewBuilder
    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !tripsCoveringSelected.isEmpty {
                // Travel mode: the planner stands down. A handover day (land
                // from trip A, leave for trip B) renders a card PER TRIP THAT
                // HAS A JOURNEY today — but trips with nothing to show share
                // ONE quiet card instead of stacking three identical "Nothing
                // to catch today" boxes (which is exactly what the legacy
                // overlapping Bali trips did).
                let withJourneys = tripsCoveringSelected.filter { trip in
                    allTravelSegments.contains {
                        $0.tripID == trip.id && Calendar.current.isDate($0.day, inSameDayAs: selectedDate)
                    }
                }
                ForEach(withJourneys, id: \.id) { trip in
                    TravelDayCard(trip: trip, day: selectedDate)
                }
                if withJourneys.isEmpty {
                    TravelQuietDayCard(trips: tripsCoveringSelected,
                                       onOpen: { editingTrip = $0 })
                }
                eventsSection
            } else {
                if let s = travelSuggestion { travelSuggestionBanner(s) }
                eventsSection
                gymCard
                planBar
                planCard
            }
        }
    }

    // MARK: Travel detection

    /// Does the selected day look like travel? Built from the day's events plus
    /// whatever journey times we've been able to measure.
    private var travelSuggestion: TravelDetection.Suggestion? {
        guard tripCovering(selectedDate) == nil else { return nil }
        guard !dismissedTravelDays.contains(selectedDate.startOfDay) else { return nil }
        let cal = Calendar.current
        let dayEvents = events.filter { cal.isDate($0.date, inSameDayAs: selectedDate) }
        guard !dayEvents.isEmpty else { return nil }

        let candidates = dayEvents.map { e -> TravelDetection.Candidate in
            // Prefer the span the calendar actually told us; fall back to
            // inferring it from same-titled rows on consecutive days (events
            // built by hand, day by day).
            let inferred = TravelDetection.spanDays(title: e.title,
                                                    days: events.filter { $0.title == e.title }.map(\.date),
                                                    calendar: cal)
            return TravelDetection.Candidate(
                title: e.title,
                day: cal.startOfDay(for: e.date),
                isAllDay: e.isAllDay,
                hasLocation: !e.destinationAddress.isEmpty,
                eventMinutes: max(0, e.endMinute - e.startMinute),
                journeyMinutes: measuredJourneys[e.destinationAddress],
                spanDays: max(e.spanDays, inferred))
        }
        return TravelDetection.suggestion(for: candidates, calendar: cal)
    }

    private func travelSuggestionBanner(_ s: TravelDetection.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "airplane.departure").font(.system(size: 13, weight: .semibold))
                Text("LOOKS LIKE TRAVEL").font(.system(size: 10.5, weight: .bold)).kerning(1.1)
                Spacer()
            }
            .foregroundStyle(Color.travelInk)
            Text(s.reason)
                .font(.system(size: 13))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Travel mode stops me filling these days with your routine. You'd get journeys and leave-by times instead.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { acceptTravel(s) } label: {
                    Text(s.startDay == s.endDay ? "Switch this day" : "Switch these \(dayCount(s)) days")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Color.travelInk))
                }
                .buttonStyle(.plain)
                Button { dismissedTravelDays.insert(selectedDate.startOfDay) } label: {
                    Text("Not travel")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textSoft)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 11).stroke(Color.textPrimary.opacity(0.15), lineWidth: 1.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.travelBg))
    }

    private func dayCount(_ s: TravelDetection.Suggestion) -> Int {
        (Calendar.current.dateComponents([.day], from: s.startDay, to: s.endDay).day ?? 0) + 1
    }

    /// Build the whole trip, not just the day in front of us. Every event that
    /// overlaps the suggested range becomes a stay; overlaps resolve in favour
    /// of the later start (a new stay beginning means you moved), and the trip
    /// spans the union. This is what turns "Bali 3–12" + "Travel to Singapore
    /// 11–14" into one 3–14 Sep trip with two legs and a move on the 11th.
    private func acceptTravel(_ s: TravelDetection.Suggestion) {
        // One range, one trip: if any existing trip touches these days, open it
        // rather than stacking a second one on top (overlapping trips made
        // tripCovering effectively arbitrary).
        if let existing = trips.first(where: { !($0.endDate < s.startDay || $0.startDate > s.endDay) }) {
            editingTrip = existing
            return
        }
        let cal = Calendar.current
        let overlapping = events.filter { e in
            let end = e.spanEndDate ?? e.date
            return end >= s.startDay && e.date <= s.endDay && !e.destinationAddress.isEmpty
        }
        // The SAME calendar event can exist as several rows (synced from
        // different days before re-syncs became idempotent). Group by identity
        // first, or each copy becomes its own stay — which is how a trip once
        // got titled "Bali + Bali + Bali" with flights from Bali to Bali.
        let grouped = Dictionary(grouping: overlapping) {
            $0.externalID.isEmpty ? "title:\($0.title)" : $0.externalID
        }
        let spans = grouped.values.compactMap { rows -> Itinerary.Span? in
            guard let first = rows.min(by: { $0.date < $1.date }) else { return nil }
            let end = rows.compactMap { $0.spanEndDate ?? $0.date }.max() ?? first.date
            return Itinerary.Span(place: first.title,
                                  start: cal.startOfDay(for: first.date),
                                  end: cal.startOfDay(for: end),
                                  externalID: first.externalID,
                                  address: rows.first { !$0.destinationAddress.isEmpty }?.destinationAddress ?? "")
        }
        let resolved = Itinerary.resolveOverlaps(spans, calendar: cal)
        let bounds = Itinerary.bounds(resolved)
        let trip = Trip(title: resolved.count > 1
                            ? resolved.map(\.place).joined(separator: " + ")
                            : s.title,
                        startDate: bounds?.start ?? s.startDay,
                        endDate: bounds?.end ?? s.endDay)
        modelContext.insert(trip)
        for span in resolved {
            modelContext.insert(TripStay(tripID: trip.id, place: span.place, address: span.address,
                                         arriveDate: span.start, departDate: span.end,
                                         externalID: span.externalID))
        }
        // Each move gets a journey ready for its times — the only days of a
        // trip where anything is time-critical. A "move" between the same
        // place is a data artifact, never a journey.
        var createdTransitions: [TravelSegment] = []
        for t in Itinerary.transitions(resolved)
        where t.from.place != t.to.place && t.from.address != t.to.address {
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: t.day) ?? t.day
            // A move between two stays is a DRIVE until the user says
            // otherwise: both ends are street addresses, and .flight dressed a
            // 2 h lodge transfer in a 3 h airline cut-off, telling the user to
            // leave at 05:55 for a noon drive. Drives take an arrive-by, not a
            // departure.
            let seg = TravelSegment(
                tripID: trip.id, mode: .drive,
                label: "\(t.from.place) → \(t.to.place)",
                fromPlace: t.from.address, toPlace: t.to.address,
                arriveBy: noon,
                checkInMinutes: 0, securityMinutes: 0)
            modelContext.insert(seg)
            createdTransitions.append(seg)
        }
        modelContext.saveOrLog("DayPlanner.acceptTravel")
        EventLog.log(.tripCreated, "\(trip.title) \(TravelGuard.dayRange(trip)) from calendar banner",
                     subject: trip.id, context: modelContext)
        // The trip now owns these days — stale plans and their notifications go.
        Task { await TravelGuard.sweep(context: modelContext) }
        // Measure the auto-created transfers now: a leave-by of "arrival minus
        // buffer" with 0 min of driving is not a chain, and no nudge exists
        // until a real journey time does. (Scenario eval: accepted trips sat
        // unmeasured until the user found the Measure button.)
        let toMeasure = createdTransitions
        Task {
            for seg in toMeasure where seg.travelMinutes == 0 && !seg.toPlace.isEmpty {
                if let m = await GoogleMapsService.commuteMinutes(
                    from: seg.fromPlace, to: seg.toPlace,
                    departure: max(seg.arriveBy ?? Date(), Date())) {
                    seg.travelMinutes = m
                    seg.travelIsEstimated = false
                    modelContext.saveOrLog("DayPlanner.measureTransition")
                    EventLog.log(.journeyMeasured, "\(seg.label) — \(m) min at acceptance",
                                 subject: seg.id, context: modelContext)
                    await TravelGuard.absorb(seg, context: modelContext)
                    await TravelNotifier.schedule(segment: seg)
                }
            }
        }
        editingTrip = trip
    }

    /// Measure the journey to each of the day's venues once, so the distance
    /// rules have something to work with. Unmeasured stays nil — never guessed.
    private func measureJourneys() {
        let cal = Calendar.current
        let venues = Set(events
            .filter { cal.isDate($0.date, inSameDayAs: selectedDate) && !$0.destinationAddress.isEmpty }
            .map(\.destinationAddress))
        let pending = venues.subtracting(measuredJourneys.keys)
        guard !pending.isEmpty else { return }
        let home = locations.first { $0.kind == .home }?.address ?? "Home"
        Task {
            for v in pending {
                if let m = await GoogleMapsService.commuteMinutes(from: home, to: v) {
                    measuredJourneys[v] = m
                }
            }
        }
    }

    /// The trip that puts this day in travel mode, if any.
    private var tripsCoveringSelected: [Trip] {
        TravelGuard.tripsCovering(selectedDate, context: modelContext)
    }

    private func tripCovering(_ day: Date) -> Trip? {
        trips.first { $0.covers(day) }
    }

    /// Open the trip covering the selected day, or start one that begins there.
    /// A one-day trip is a perfectly good travel day; extend it in the editor.
    private func openOrCreateTrip() {
        if let existing = tripCovering(selectedDate) {
            editingTrip = existing
            return
        }
        let trip = Trip(title: "Trip", startDate: selectedDate, endDate: selectedDate)
        modelContext.insert(trip)
        modelContext.saveOrLog("DayPlanner.newTrip")
        editingTrip = trip
    }

    // MARK: Plan my day (persisted, Claude-first)

    /// The committed plan for the selected day, if one has been generated.
    private var savedPlan: GeneratedPlan? { selectedPlanState?.plan }

    private var planBar: some View {
        VStack(spacing: 8) {
            Button(action: planMyDay) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold))
                    Text(savedPlan == nil ? "Plan my day" : "Re-plan").font(.serif(16))
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
            if let replanNote {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.sageDeep)
                    Text(replanNote).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.textSoft)
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Capsule().fill(Color.sage.opacity(0.16)))
            }
        }
    }

    @ViewBuilder
    private var planCard: some View {
        if let plan = savedPlan {
            let inferred = AdherenceEngine.infer(plan: plan, evidence: evidence(for: selectedDate),
                                                 cutoffMinute: adherenceCutoff)
            let effective = AdherenceEngine.effective(plan: plan, inferred: inferred,
                                                      manual: selectedPlanState?.manualOutcomes ?? [:])
            HStack {
                Spacer()
                Button { showPlanEditor = true } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentDeep)
                }
            }
            PlanTimelineCard(
                plan: plan,
                isOffline: selectedPlanState?.generatedPlanIsOffline ?? false,
                outcomes: outcomeMap(plan, effective),
                onToggle: { block, current in toggleOutcome(block, current: current) }
            )
            adherenceCard(plan: plan, outcomes: effective)
        }
    }

    private func outcomeMap(_ plan: GeneratedPlan, _ effective: [BlockOutcome]) -> [String: BlockOutcome] {
        Dictionary(zip(plan.blocks.map(AdherenceEngine.key), effective), uniquingKeysWith: { _, b in b })
    }

    /// Cycle a block's manual mark: none → done → skipped → none.
    private func toggleOutcome(_ block: GeneratedBlock, current: BlockOutcome) {
        guard let state = selectedPlanState else { return }
        let next: BlockOutcome? = current == .done ? .skipped : (current == .skipped ? nil : .done)
        state.setManualOutcome(next, forKey: AdherenceEngine.key(block))
        modelContext.saveOrLog()
    }

    /// Persist a hand-edited plan and reschedule its reminders.
    private func commitEditedPlan(_ plan: GeneratedPlan) {
        guard let state = selectedPlanState else { return }
        state.storePlan(plan, isOffline: state.generatedPlanIsOffline)
        modelContext.saveOrLog()
        let date = selectedDate
        Task { await NotificationService.reschedule(plan: plan, on: date) }
    }

    // MARK: Adherence — was the plan followed? (inferred from the day's logs)

    private func evidence(for date: Date) -> DayEvidence {
        // Shared with the history builder (AdherenceHistory) so the live card and
        // the adaptive-planning signal read the logs identically.
        AdherenceHistory.evidence(day: date.startOfDay, checkins: checkins, prep: prepSessions,
                                  jobs: jobApplications, reading: readingLogs, leisure: leisureLogs)
    }

    /// The "as of now" cutoff for judging the selected day: nil for a past day
    /// (everything elapsed), the current minute for today (don't pre-judge blocks
    /// that haven't happened), and -1 for a future day (nothing elapsed).
    private var adherenceCutoff: Int? {
        let sel = selectedDate.startOfDay
        if sel < today { return nil }
        if sel > today { return -1 }
        let c = Calendar.current
        return c.component(.hour, from: Date()) * 60 + c.component(.minute, from: Date())
    }

    @ViewBuilder
    private func adherenceCard(plan: GeneratedPlan, outcomes: [BlockOutcome]) -> some View {
        let assessed = AdherenceEngine.assessableCount(outcomes)
        let routine = Baseline.routine(from: routineActivities)
        let reviewable = selectedDate.startOfDay <= today
        if reviewable, let score = AdherenceEngine.weightedScore(plan: plan, outcomes: outcomes, routine: routine), assessed > 0 {
            let pct = Int((score * 100).rounded())
            let done = outcomes.filter { $0 == .done }.count
            HStack(spacing: 12) {
                Text("\(pct)%").font(.serif(26)).foregroundStyle(Color.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan followed").font(.serif(15)).foregroundStyle(Color.textPrimary)
                    // Every activity is markable, not just the auto-tracked ones —
                    // Jeeves learns from all of them and adapts your coming days.
                    Text("\(done) of \(assessed) so far — tap any activity above to mark it done or skipped. Jeeves learns from all of them.")
                        .font(.system(size: 12)).foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
            .task(id: "\(selectedDate.timeIntervalSince1970)-\(pct)-\(assessed)") {
                if let state = selectedPlanState {
                    state.adherenceScore = score
                    state.adherenceAssessed = assessed
                    modelContext.saveOrLog()
                }
            }
        } else if reviewable {
            // Nothing assessed yet — invite feedback on the whole day, so the
            // app learns from every activity, not just the log-inferred ones.
            HStack(spacing: 10) {
                Image(systemName: "checklist").font(.system(size: 19)).foregroundStyle(Color.accent)
                Text("How did the day go? Tap each activity above to mark it done or skipped — Jeeves learns from all of them and adapts your coming days.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.textSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
        }
    }

    private func planMyDay() {
        // A trip owns its days: the button is hidden on travel days, but the
        // rule is enforced here too so no path around the UI can plan one.
        if let trip = tripCovering(selectedDate) {
            EventLog.log(.planRefusedTravel, "planner button refused (\(trip.title))",
                         context: modelContext)
            planError = TravelGuard.refusalMessage(for: selectedDate, trip: trip)
            return
        }
        planError = nil
        isPlanning = true
        let date = selectedDate
        let dayEvents = selectedEvents
        // Mid-day re-plan: when re-planning TODAY and the committed plan already has
        // blocks that have elapsed, lock those and rebuild only from now — so moving
        // an anchor at 3pm doesn't wipe the reading/shower already done this morning.
        let nowMinute = DayPlannerView.minuteOfDay(Date())
        var replanFrom: Int? = nil
        var lockedNow: [GeneratedBlock] = []
        var doneNote: String? = nil
        replanNote = nil
        if date == today, let current = savedPlan {
            let elapsed = PlanCoordinator.lockedBlocks(current, endedBy: nowMinute)
            if !elapsed.isEmpty {
                replanFrom = nowMinute
                lockedNow = elapsed
                doneNote = "Already done earlier today: " + elapsed.map(\.title).joined(separator: ", ")
                replanNote = "Re-planned from \(DayPlannerView.clockLabel(nowMinute)) · kept \(elapsed.count) earlier block\(elapsed.count == 1 ? "" : "s")"
            }
        }
        Task {
            // Hold a background assertion so planning survives the user
            // switching away mid-request (otherwise iOS tears the call down and
            // it falls back to the offline plan).
            let result = await BackgroundActivity.run("plan-my-day") {
                await PlanCoordinator.generateLogged(.init(
                    hasGym: hasGymToday,
                    gymMinute: gymMinute,
                    events: dayEvents,
                    locations: locations,
                    prepSessions: prepSessions,
                    routine: Baseline.routine(from: routineActivities),
                    adherenceNote: AdherenceHistory.planningNote(context: modelContext, for: date),
                    replanFromMinute: replanFrom,
                    alreadyDoneNote: doneNote,
                    lockedBlocks: lockedNow,
                    planDate: date
                ), context: modelContext, trigger: .planner)
            }
            // Commit to this date's plan state so it persists and displays here.
            let state = DailyPlanState.fetchOrCreate(for: date, in: modelContext,
                                                     hasGymToday: hasGymToday, gymMinute: gymMinute)
            state.storePlan(result.plan, isOffline: result.isOffline)
            modelContext.saveOrLog()
            await NotificationService.reschedule(plan: result.plan, on: date)
            // If they backgrounded the app while it planned, tell them it's ready.
            await NotificationService.notifyPlanReady(isOffline: result.isOffline)
            // Arm a background traffic re-check ~90 min before the next commute.
            CommuteBackgroundRefresh.scheduleNext(context: modelContext)
            if result.isOffline { planError = "Couldn't reach the planning service — showing an offline plan.\(result.error.map { " (\($0))" } ?? "")" }
            isPlanning = false
        }
    }

    /// Minutes since midnight for a wall-clock time.
    static func minuteOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// A minutes-since-midnight value as a 12-hour clock label ("3:00 PM").
    static func clockLabel(_ minute: Int) -> String {
        let h = minute / 60, m = minute % 60
        let ampm = h < 12 ? "AM" : "PM"
        var h12 = h % 12; if h12 == 0 { h12 = 12 }
        return String(format: "%d:%02d %@", h12, m, ampm)
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
                        .font(.serif(numberSize))
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
                var evs = try await GoogleCalendarService.events(on: day)
                // A deleted synced event stays deleted: tombstoned IDs are
                // not even offered for re-import (they'd be pre-checked and
                // quietly resurrected on confirm).
                let dead = CalendarTombstone.ids(in: modelContext)
                evs.removeAll { !$0.externalID.isEmpty && dead.contains($0.externalID) }
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
            // Google's event id makes re-syncing idempotent: the SAME calendar
            // event — synced again today, or from a different day of its span —
            // updates the record we already have instead of spawning a copy.
            // (Syncing "Bali" from the 4th, 5th and 7th once produced three
            // extra single-day Balis and a trip titled "Bali + Bali + Bali".)
            if !c.externalID.isEmpty,
               let existing = events.first(where: { $0.externalID == c.externalID }) {
                existing.title = c.title
                existing.isAllDay = c.isAllDay
                existing.startMinute = c.startMinute
                existing.endMinute = c.endMinute
                if let s = c.startDay { existing.date = s }
                existing.spanEndDate = c.spanDays > 1 ? c.endDay : nil
                if !c.location.isEmpty, c.location != existing.destinationAddress {
                    existing.destinationAddress = c.location
                    existing.destinationLat = nil     // stale pin for the old venue
                    existing.destinationLng = nil
                }
                // If this event backs a trip's stay, the trip must follow the
                // edit: move the stay, grow the window, sweep the newly
                // covered days.
                let extID = c.externalID
                let newStart = c.startDay ?? existing.date
                let newEnd = c.endDay ?? existing.spanEndDate ?? existing.date
                let title = c.title
                let address = c.location
                Task {
                    await TravelGuard.absorbStay(externalID: extID, title: title, address: address,
                                                 newStart: newStart, newEnd: newEnd,
                                                 context: modelContext)
                }
                continue
            }
            let dup = events.contains {
                $0.date == calendarReview?.date && $0.title == c.title && $0.startMinute == c.startMinute
            }
            guard !dup, let day = calendarReview?.date else { continue }
            modelContext.insert(DailyEvent(
                date: c.startDay ?? day, title: c.title,
                startMinute: c.startMinute, endMinute: c.endMinute,
                destinationAddress: c.location, outboundStart: .home, source: .calendar,
                isAllDay: c.isAllDay,
                // Carry the event's full span, so a multi-day trip is set up
                // from a single sync instead of one orphaned day.
                spanEndDate: c.spanDays > 1 ? c.endDay : nil,
                externalID: c.externalID
            ))
        }
        modelContext.saveOrLog()
        EventLog.log(.calendarSynced, "\(chosen.count) event(s) confirmed from Google Calendar",
                     context: modelContext)
        if let day = calendarReview?.date { selectedDate = day }
    }

    private func eventRow(_ event: DailyEvent) -> some View {
        Button { editEvent(event) } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(event.isAllDay ? "All day" : hhmm(event.startMinute))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.accentDeep)
                    .frame(width: 52, alignment: .trailing)
                Rectangle().fill(Color.accent).frame(width: 3).cornerRadius(1.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.serif(16))
                        .foregroundStyle(Color.textPrimary)
                    Text(event.isAllDay
                         ? "All day · from \(event.outboundStart.rawValue)"
                         : "\(hhmm(event.startMinute))–\(hhmm(event.endMinute)) · from \(event.outboundStart.rawValue)")
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
        eventDraft = EventDraft(on: selectedDate)
    }

    private func editEvent(_ event: DailyEvent) {
        eventDraft = EventDraft(event: event)
    }

    private func saveEvent(_ draft: EventDraft) {
        if let event = draft.existingEvent {
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
        modelContext.saveOrLog()
        selectedDate = draft.date.startOfDay   // follow the event to its day
    }

    private func delete(event: DailyEvent) {
        // Same rule as the chat path: a deleted synced event must never
        // be resurrected by the next calendar sync.
        if !event.externalID.isEmpty {
            modelContext.insert(CalendarTombstone(externalID: event.externalID))
        }
        modelContext.delete(event)
        modelContext.saveOrLog()
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
            // Travel mode: open the trip covering this day, or start one from it.
            Button { openOrCreateTrip() } label: {
                Circle()
                    .fill(tripCovering(selectedDate) != nil ? Color.travelBg : Color.surface)
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: "airplane")
                        .foregroundStyle(tripCovering(selectedDate) != nil ? Color.travelInk : Color.textSoft)
                        .font(.system(size: 15)))
            }
            .buttonStyle(.plain)
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
                Text(isToday ? "Gym today" : "Gym this day").font(.serif(17)).foregroundStyle(Color.textPrimary)
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
        let state = DailyPlanState.fetchOrCreate(for: selectedDate, in: modelContext,
                                                 hasGymToday: hasGymToday, gymMinute: gymMinute)
        state.hasGymToday = hasGymToday
        state.gymMinute = gymMinute
        modelContext.saveOrLog()
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
                                    Text(event.title).font(.serif(15)).foregroundStyle(Color.textPrimary)
                                    Text((event.isAllDay ? "All day" : "\(hhmm(event.startMinute))–\(hhmm(event.endMinute))") + (event.location.isEmpty ? "" : " · \(event.location)"))
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
