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
    @Query private var activitySessions: [ActivitySession]
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
    @State private var showPicker = false
    @State private var showDeviceCalendars = false
    @State private var planningStartedAt = Date()
    @State private var planningTask: Task<Void, Never>?
    @State private var planError: String?
    @State private var replanNote: String? = nil

    // Google Calendar import (reviewed, not silent).
    @State private var calendarReview: CalendarReview?
    @State private var isImportingCalendar = false
    @State private var calendarError: String?
    @State private var showPlanEditor = false
    @State private var showDateJump = false
    @State private var showTicketImport = false

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
        .sheet(isPresented: $showTicketImport) { TicketImportView() }
        .sheet(isPresented: $showPicker) { pickerSheet }
        .sheet(isPresented: $showDeviceCalendars) {
            DeviceCalendarsSheet { _ in importFromDeviceCalendars() }
        }
        .sheet(isPresented: $showDateJump) {
            DateJumpSheet(selectedDate: $selectedDate, today: today)
                .presentationDetents([.height(460)])
                .presentationDragIndicator(.visible)
        }
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
                stalePlanBanner
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
        // Any event COVERING the day, not only one that starts on it. A
        // multi-day block is stored as a single row dated its first day, so
        // the banner existed on 4 Sep and nowhere else — scroll to the 6th of
        // an unaccepted eight-day trip and the planner offered an ordinary
        // Saturday with no hint that a trip was sitting in the calendar.
        let dayEvents = events.filter { e in
            let start = cal.startOfDay(for: e.date)
            let end = cal.startOfDay(for: e.spanEndDate ?? e.date)
            let day = cal.startOfDay(for: selectedDate)
            return day >= start && day <= end
        }
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
                spanDays: max(e.spanDays, inferred),
                ownSpanDays: e.spanDays)
        }
        return TravelDetection.suggestion(for: candidates, calendar: cal)
    }

    private func travelSuggestionBanner(_ s: TravelDetection.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "airplane.departure").font(.ui(13, weight: .semibold))
                Text("LOOKS LIKE TRAVEL").font(.ui(10.5, weight: .bold)).kerning(1.1)
                Spacer()
            }
            .foregroundStyle(Color.travelInk)
            Text(s.reason)
                .font(.ui(13))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Travel mode stops me filling these days with your routine. You'd get journeys and leave-by times instead.")
                .font(.ui(11.5))
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { acceptTravel(s) } label: {
                    Text(s.startDay == s.endDay ? "Switch this day" : "Switch these \(dayCount(s)) days")
                        .font(.ui(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Color.travelInk))
                }
                .buttonStyle(.plain)
                Button { dismissedTravelDays.insert(selectedDate.startOfDay) } label: {
                    Text("Not travel")
                        .font(.ui(13, weight: .semibold))
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
        // A single-day event still needs an address to count as a place —
        // otherwise "Dentist" on day three of a holiday becomes a stay. A
        // multi-day block is a place-window without one, which is why "Bali
        // 4–11 Sep" typed as a bare title produced a trip with no stays at all.
        //
        // Which address-less blocks are PLACES rather than things happening
        // during one? Matching the banner's own title was too strict: "Bali
        // 4–11" and "Singapore 11–14" are two legs of one trip, and admitting
        // only the first built a Bali-only trip with no move on the 11th and a
        // "7 or 8 nights" hedge over data that settles it at 7.
        //
        // The real discriminator is containment. A "Sprint review 8–9 Sep"
        // sits wholly INSIDE Bali 4–11 — it is an event during a stay, and
        // admitting it truncated Bali to the 7th. A block that extends beyond
        // its neighbour is a separate leg. Nothing about the title is needed.
        let candidateRows = events.filter { e in
            let end = e.spanEndDate ?? e.date
            return end >= s.startDay && e.date <= s.endDay
        }
        let addressed = candidateRows.filter { !$0.destinationAddress.isEmpty }
        let bareMultiDay = candidateRows.filter { $0.destinationAddress.isEmpty && $0.spanDays > 1 }
        let placeLike = addressed + bareMultiDay.filter { candidate in
            let cStart = cal.startOfDay(for: candidate.date)
            let cEnd = cal.startOfDay(for: candidate.spanEndDate ?? candidate.date)
            // Contained in some OTHER place-like block? Then it is an event
            // inside a stay, not a stay of its own.
            return !(addressed + bareMultiDay).contains { other in
                guard other.id != candidate.id else { return false }
                let oStart = cal.startOfDay(for: other.date)
                let oEnd = cal.startOfDay(for: other.spanEndDate ?? other.date)
                let strictlyWider = (oEnd.timeIntervalSince(oStart)) > (cEnd.timeIntervalSince(cStart))
                return oStart <= cStart && cEnd <= oEnd && strictlyWider
            }
        }
        let overlapping = placeLike
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
                                  address: rows.first { !$0.destinationAddress.isEmpty }?.destinationAddress ?? "",
                                  // A calendar block cannot say whether its last
                                  // day is a night there or the morning you go.
                                  // resolveOverlaps settles it for any stay a
                                  // later one follows; the last stay keeps the
                                  // doubt, and the count is rendered as a pair.
                                  endIsUnsettled: true)
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
            // A Span's `end` is the last NIGHT; a TripStay's `departDate` is the
            // last day you are PRESENT — the day you leave, which is what
            // covers() needs and what the ticket importer writes. Converting
            // here is what stops one field meaning two things depending on
            // which importer filled it.
            //
            // A settled end converts exactly: moving on the 20th means the 19th
            // was the last night, so you are present on the 20th. An unsettled
            // end cannot be converted, because we do not know whether the
            // calendar's last day was a night or a departure — so it is stored
            // as-is and the flag travels with it.
            let depart = span.endIsUnsettled
                ? span.end
                : (cal.date(byAdding: .day, value: 1, to: span.end) ?? span.end)
            modelContext.insert(TripStay(tripID: trip.id, place: span.place, address: span.address,
                                         arriveDate: span.start, departDate: depart,
                                         externalID: span.externalID,
                                         // Carry the doubt into the store. A Span
                                         // lives for one call; the stay outlives it.
                                         endIsUnsettled: span.endIsUnsettled))
        }
        // Each move gets a journey ready for its times — the only days of a
        // trip where anything is time-critical. A "move" between the same
        // place is a data artifact, never a journey.
        var createdTransitions: [TravelSegment] = []
        for t in Itinerary.transitions(resolved)
        // Different places, and not the same address twice. The old test was
        // `from.address != to.address`, which is FALSE when both are empty — so
        // two address-less stays produced no journey at all, and the move on
        // the handover day existed nowhere.
        where t.from.place != t.to.place
           && !(!t.from.address.isEmpty && t.from.address == t.to.address) {
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: t.day) ?? t.day
            // A move between two stays is a DRIVE until the user says
            // otherwise: both ends are street addresses, and .flight dressed a
            // 2 h lodge transfer in a 3 h airline cut-off, telling the user to
            // leave at 05:55 for a noon drive. Drives take an arrive-by, not a
            // departure.
            //
            // But nobody CHOSE it, and the same default calls Bali → Singapore
            // a drive. `modeIsAssumed` carries that, so the card can say so and
            // the first measurement can refute it.
            let seg = TravelSegment(
                tripID: trip.id, mode: .drive,
                label: "\(t.from.place) → \(t.to.place)",
                fromPlace: t.from.address, toPlace: t.to.address,
                arriveBy: noon,
                checkInMinutes: 0, securityMinutes: 0,
                modeIsAssumed: true)
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
                // A segment can be deleted from the editor that just opened
                // while this is in flight; mutating a deleted model is a crash.
                guard !seg.isDeleted else { continue }
                let ends = JourneyMeasurement.endpoints(of: seg.label,
                                                        fallbackFrom: seg.fromPlace,
                                                        fallbackTo: seg.toPlace)
                let decision = await JourneyMeasurement.apply(
                    to: seg, from: seg.fromPlace, to: seg.toPlace,
                    departure: max(seg.arriveBy ?? Date(), Date()), label: ends)

                EventLog.log(.journeyMeasured,
                             "\(seg.label) — \(decision.minutes.map { "\($0) min" } ?? "no reading")"
                             + (decision.settlesMode ? " at acceptance" : "; assumed drive not settled"),
                             subject: seg.id, context: modelContext)
                modelContext.saveOrLog("DayPlanner.measureTransition")

                // Only a journey we believe in gets to grow the trip and wake
                // the user. A refuted drive kept its chain and kept nudging.
                guard decision.mayNudge else { continue }
                await TravelGuard.absorb(seg, context: modelContext)
                await TravelNotifier.schedule(segment: seg)
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
        // No saved home means no measurement. The old fallback POSTed the word
        // "Home" to Routes and rendered whatever came back as measured.
        guard let home = RoutableOrigin.address(locations.first(where: { $0.kind == .home })?.address)
        else { return }
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

    /// Shown when the day's inputs moved after its plan was built.
    ///
    /// The app knew the plan was wrong and showed it anyway — an appointment
    /// deleted in chat stayed on the timeline, and its "time to leave" push
    /// stayed armed. Knowing and not saying is the part this fixes; the rebuild
    /// stays the user's call.
    @ViewBuilder
    private var stalePlanBanner: some View {
        if let state = selectedPlanState, state.isPlanStale {
            Button(action: planMyDay) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.ui(13, weight: .semibold))
                        .foregroundStyle(Color.accentDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This plan is out of date")
                            .font(.ui(13.5, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text("\(state.planStaleReason.map { $0.prefix(1).capitalized + $0.dropFirst() } ?? "Something changed") after it was built. Tap to rebuild the day.")
                            .font(.ui(12)).foregroundStyle(Color.textSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 13).padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentDeep.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isPlanning)
        }
    }

    /// The activity picker, over the day currently on screen.
    private var pickerSheet: some View {
        ActivityPickerSheet(day: selectedDate) { _ in
            showPicker = false
            planMyDay()
        }
    }

    private var planBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: planMyDay) {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars").font(.ui(13, weight: .semibold))
                        Text(savedPlan == nil ? "Plan my day" : "Re-plan").font(.serif(16))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.accent))
                }
                .buttonStyle(.plain)
                .disabled(isPlanning)

                // Choose the day's activities before planning it. Sits beside
                // the plan button rather than inside a menu: it is the answer
                // to "not today", and that question comes up daily.
                Button { showPicker = true } label: {
                    Image(systemName: "checklist")
                        .font(.ui(15, weight: .semibold))
                        .foregroundStyle(Color.accentDeep)
                        .frame(width: 48, height: 46)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
                }
                .buttonStyle(.plain)
                .disabled(isPlanning)
                .accessibilityLabel("Choose this day's activities")
            }

            if isPlanning {
                PlanningProgressCard(startedAt: planningStartedAt) { cancelPlanning() }
            }
            if let planError {
                Text(planError).font(.ui(12)).foregroundStyle(Color.accentDeep)
            }
            if let replanNote {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").font(.ui(12)).foregroundStyle(Color.sageDeep)
                    Text(replanNote).font(.ui(11.5, weight: .medium)).foregroundStyle(Color.textSoft)
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
                        .font(.ui(13, weight: .semibold)).foregroundStyle(Color.accentDeep)
                }
            }
            // A running session sits above the timeline: one clock, and it is
            // the thing you'd reach for while it's going.
            if let live = activitySessions.first(where: { $0.isLive }) {
                ActivitySessionBar(session: live, plan: plan)
            }
            PlanTimelineCard(
                plan: plan,
                isOffline: selectedPlanState?.generatedPlanIsOffline ?? false,
                outcomes: outcomeMap(plan, effective),
                onToggle: { block, current in toggleOutcome(block, current: current) },
                onStart: isToday ? { block in startSession(block) } : nil,
                startableKeys: startableKeys(plan)
            )
            adherenceCard(plan: plan, outcomes: effective)
        }
    }

    private func outcomeMap(_ plan: GeneratedPlan, _ effective: [BlockOutcome]) -> [String: BlockOutcome] {
        Dictionary(zip(plan.blocks.map(AdherenceEngine.key), effective), uniquingKeysWith: { _, b in b })
    }

    /// Blocks that can be timed: measurable, and not already logged. Commutes,
    /// lunch, chores and the gym never offer a Start — there is nothing to
    /// count, and the gym is logged on the Watch in far more detail.
    private func startableKeys(_ plan: GeneratedPlan) -> Set<String> {
        guard isToday, !onTravelDay else { return [] }
        let logged = Set(ActivitySession.onDay(selectedDate, in: modelContext)
            .filter { !$0.isLive }.map(\.blockKey))
        return Set(plan.blocks
            .filter { ActivityUnit.isMeasurable(title: $0.title, kind: $0.kind) }
            .map(AdherenceEngine.key)
            .filter { !logged.contains($0) })
    }

    /// No timing on travel days — the app already stands the routine plan down
    /// on any day a trip covers, and nudging a prep block while you're driving
    /// to Wayanad is the failure that rule exists to prevent.
    private var onTravelDay: Bool {
        trips.contains { $0.covers(selectedDate) }
    }

    private func startSession(_ block: GeneratedBlock) {
        let planned = (block.endMinute ?? 0) - (block.startMinute ?? 0)
        ActivityTracker.start(blockKey: AdherenceEngine.key(block), title: block.title,
                              plannedMinutes: max(0, planned), day: selectedDate,
                              context: modelContext)
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
                                  jobs: jobApplications, reading: readingLogs, leisure: leisureLogs,
                                  sessions: activitySessions,
                                  neverAsked: selectedPlanState?.withheldKeys ?? [])
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
                Text("\(pct)%").font(.serif(26)).foregroundStyle(Color.accentDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan followed").font(.serif(15)).foregroundStyle(Color.textPrimary)
                    // Every activity is markable, not just the auto-tracked ones —
                    // Jeeves learns from all of them and adapts your coming days.
                    Text("\(done) of \(assessed) so far — tap any activity above to mark it done or skipped. Jeeves learns from all of them.")
                        .font(.ui(12)).foregroundStyle(Color.textMuted)
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
                Image(systemName: "checklist").font(.ui(19)).foregroundStyle(Color.accentDeep)
                Text("How did the day go? Tap each activity above to mark it done or skipped — Jeeves learns from all of them and adapts your coming days.")
                    .font(.ui(12.5)).foregroundStyle(Color.textSoft)
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
        replanNote = nil
        // The elapsed-day arithmetic used to live here, and only here plus one
        // chat tool — so the same button pressed inside chat rebuilt the day
        // from 08:00. The coordinator owns it now; this hands over the day's
        // committed plan and lets it decide.
        let selection = selectedPlanState?.activitySelection ?? .routine
        planningStartedAt = Date()
        planningTask = Task {
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
                    routine: Baseline.routine(from: routineActivities, selection: selection),
                    gymSession: Baseline.gymSession(from: routineActivities),
                    adherenceNote: AdherenceHistory.planningNote(context: modelContext, for: date),
                    planDate: date,
                    existingPlan: date == today ? savedPlan : nil,
                    blankDay: selection.isBlankDay
                ), context: modelContext, trigger: .planner)
            }
            // Stopping must actually stop. The request can still finish (or
            // fall back offline) after the user taps cancel, and committing
            // that would overwrite the plan they chose to keep.
            if Task.isCancelled {
                isPlanning = false
                return
            }
            // Commit to this date's plan state so it persists and displays here.
            // ONE shared commit: this path used to schedule the block reminders
            // but never the timing nudges, so the T-10/+15/+30 chain simply did
            // not exist on any day planned from this button.
            await PlanCoordinator.commit(result, on: date, context: modelContext,
                                         hasGymToday: hasGymToday, gymMinute: gymMinute)
            // Describe what actually happened rather than predicting it.
            if let from = result.resumedFromMinute {
                let kept = result.keptBlocks
                replanNote = "Re-planned from \(DayPlannerView.clockLabel(from))"
                    + (kept > 0 ? " · kept \(kept) earlier block\(kept == 1 ? "" : "s")" : "")
            }
            // If they backgrounded the app while it planned, tell them it's ready.
            await NotificationService.notifyPlanReady(isOffline: result.isOffline)
            if result.isOffline {
                planError = "Couldn't reach the planning service — showing an offline plan.\(result.error.map { " (\($0))" } ?? "")"
                // A fallback plan is a real plan, but not the one that was
                // asked for — say so with the hand as well as the text.
                Haptics.warning()
            } else {
                // The peak-end moment of the whole app: minutes of waiting,
                // then a day appears. It ended in silence before this.
                Haptics.success()
            }
            isPlanning = false
            planningTask = nil
        }
    }

    /// Stop waiting without losing anything. The day keeps whatever plan it
    /// already had — the in-flight request is abandoned rather than committed,
    /// so this is always safe to tap.
    private func cancelPlanning() {
        planningTask?.cancel()
        planningTask = nil
        isPlanning = false
        replanNote = nil
        planError = "Stopped planning. The plan you already had is untouched."
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
                    .font(.ui(10, weight: .semibold))
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
                    .font(.ui(12, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
                Spacer()
                // Every calendar the PHONE holds — Outlook, iCloud, Google —
                // without this app owning an OAuth flow for any of them.
                Button {
                    if EventKitService.isEnabled && EventKitService.isAuthorized {
                        importFromDeviceCalendars()
                    } else {
                        showDeviceCalendars = true
                    }
                } label: {
                    Image(systemName: "calendar")
                        .font(.ui(16))
                        .foregroundStyle(Color.accentDeep)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Add from my calendars")
                .contextMenu {
                    Button("Choose calendars…") { showDeviceCalendars = true }
                }

                Button { addEvent() } label: {
                    Label("Add", systemImage: "plus")
                        .font(.ui(13, weight: .semibold))
                        .foregroundStyle(Color.accentDeep)
                }
                .buttonStyle(.plain)
            }

            if isImportingCalendar {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading your calendar…").font(.ui(12.5)).foregroundStyle(Color.textMuted)
                }
            }
            if let calendarError {
                Text(calendarError).font(.ui(12)).foregroundStyle(Color.accentDeep)
            }

            if selectedEvents.isEmpty {
                Text(isToday ? "No events today." : "No events on this day.")
                    .font(.ui(13))
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

    /// Offer the selected day's events from every calendar on the phone.
    ///
    /// Review then confirm: nothing is written until the user ticks it,
    /// deleted events stay deleted (tombstones), and what's already on the day
    /// is only re-offered when it has actually changed.
    private func importFromDeviceCalendars() {
        Task {
            guard await EventKitService.requestAccess() else {
                showDeviceCalendars = true      // explains how to turn it on
                return
            }
            let day = selectedDate.startOfDay
            let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
            let found = EventKitService.events(from: day, to: end,
                                               calendarIDs: EventKitService.selectedCalendarIDs)
            let dead = CalendarTombstone.ids(in: modelContext)
            let offerable = found.filter { c in
                guard c.externalID.isEmpty || !dead.contains(c.externalID) else { return false }
                // An event we already hold is offered again when it has CHANGED
                // — otherwise a title-and-start match hides a wrong end time or
                // a stale address, and re-syncing can never heal a bad row.
                if let held = events.first(where: { !c.externalID.isEmpty && $0.externalID == c.externalID }) {
                    return held.endMinute != c.endMinute
                        || held.startMinute != c.startMinute
                        || held.isAllDay != c.isAllDay
                        || held.destinationAddress != c.location
                        || held.spanEndDate?.startOfDay != (c.spanDays > 1 ? c.endDay : nil)
                }
                return !selectedEvents.contains { $0.title == c.title && $0.startMinute == c.startMinute }
            }
            guard !offerable.isEmpty else {
                planError = "Nothing new in this phone's calendars for \(prettyDate(selectedDate).lowercased())."
                return
            }
            calendarReview = CalendarReview(date: day, events: offerable)
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
                    // Stale pin for the old venue — unless the calendar just
                    // handed us the new one.
                    existing.destinationLat = c.latitude
                    existing.destinationLng = c.longitude
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
            let event = DailyEvent(
                date: c.startDay ?? day, title: c.title,
                startMinute: c.startMinute, endMinute: c.endMinute,
                destinationAddress: c.location, outboundStart: .home, source: .calendar,
                isAllDay: c.isAllDay,
                // Carry the event's full span, so a multi-day trip is set up
                // from a single sync instead of one orphaned day.
                spanEndDate: c.spanDays > 1 ? c.endDay : nil,
                externalID: c.externalID
            )
            // A device calendar that carried a pin has already answered the
            // question the geocoder would be asked.
            event.destinationLat = c.latitude
            event.destinationLng = c.longitude
            modelContext.insert(event)
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
                    .font(.ui(12.5, weight: .semibold))
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
                        .font(.ui(11.5))
                        .foregroundStyle(Color.textSoft)
                    if !event.destinationAddress.isEmpty {
                        Text(event.destinationAddress)
                            .font(.ui(11.5))
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
        // Both days when an edit moves an event: the one it left is as stale as
        // the one it lands on.
        var touched: [Date] = [draft.date]
        if let existing = draft.existingEvent { touched.append(existing.date) }
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
        markStale(touched, reason: draft.existingEvent == nil ? "an event was added" : "an event was edited")
        selectedDate = draft.date.startOfDay   // follow the event to its day
    }

    /// The in-app twin of the chat executor's marker: this screen can move the
    /// same planner inputs, and used to leave the plan below it just as wrong.
    private func markStale(_ dates: [Date], reason: String,
                           clearNotifications: Bool = false) {
        var touched: [Date] = []
        for day in Set(dates.map { $0.startOfDay }) {
            let state = DailyPlanState.fetchOrCreate(for: day, in: modelContext)
            guard state.generatedPlanJSON != nil else { continue }
            state.markPlanStale(reason)
            touched.append(day)
        }
        guard !touched.isEmpty else { return }
        modelContext.saveOrLog("plan.markStale")
        guard clearNotifications else { return }
        Task { for day in touched { await NotificationService.clear(for: day) } }
    }

    private func delete(event: DailyEvent) {
        // Same rule as the chat path: a deleted synced event must never
        // be resurrected by the next calendar sync.
        if !event.externalID.isEmpty {
            modelContext.insert(CalendarTombstone(externalID: event.externalID))
        }
        let day = event.date
        modelContext.delete(event)
        modelContext.saveOrLog()
        // No notification beats a wrong one: the leave-by push for a deleted
        // appointment stays armed otherwise.
        markStale([day], reason: "an event was cancelled", clearNotifications: true)
    }

    private func prettyDate(_ date: Date) -> String {
        let base = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return date == today ? "TODAY · \(base)" : base.uppercased()
    }

    private func hhmm(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    private var header: some View {
        HStack(alignment: .center) {
            AppMenuButton()
            VStack(alignment: .leading, spacing: 1) {
                Text(selectedDate.formatted(.dateTime.month(.wide).year()).uppercased())
                    .font(.ui(11, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.textMuted)
                Text("Day Planner").font(.heading(20)).foregroundStyle(Color.textPrimary)
            }
            Spacer()
            // Travel mode: open the trip covering this day, or start one from
            // it. Those are very different consequences behind one glyph —
            // creating a trip stands the planner down for the whole day — so
            // the label says which one this tap will do.
            let hasTrip = tripCovering(selectedDate) != nil
            Menu {
                Button(hasTrip ? "Open this trip" : "Start a trip on this day") {
                    openOrCreateTrip()
                }
                // A ticket already knows the dates, the stays and every leg —
                // typing that in by hand is the slow path, not the main one.
                Button("Import a ticket…") { showTicketImport = true }
            } label: {
                Circle()
                    .fill(hasTrip ? Color.travelBg : Color.surface)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "airplane")
                        .foregroundStyle(hasTrip ? Color.travelInk : Color.textSoft)
                        .font(.ui(15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Travel")
            .accessibilityHint(hasTrip ? "Open this trip, or import a ticket"
                                       : "Start a trip, or import a ticket")
            .accessibilityHint(hasTrip ? "" : "Creates a trip covering this day and stands the planner down")
            // A calendar glyph means "pick a date" — it used to jump to today,
            // which does nothing visible on the day you are already on (the
            // default), so the button read as broken. The date dial handles
            // nearby days; this reaches the rest of the year.
            Button { showDateJump = true } label: {
                Circle()
                    .fill(Color.surface)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: isToday ? "calendar" : "calendar.badge.clock")
                        .foregroundStyle(Color.textSoft)
                        .font(.ui(15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Jump to a date")
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
                    Text("Gym starts").font(.ui(13.5)).foregroundStyle(Color.textSoft)
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
///
/// Internal, not private: PlannerSetupView had its own import path that
/// inserted every event without asking, which contradicted both this screen
/// and PRD §5.3. One review sheet, one contract.
struct CalendarImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let review: CalendarReview
    let onAdd: ([CalendarEvent]) -> Void
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your Google Calendar for \(review.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())). Pick which to add to your planner.")
                        .font(.ui(13)).foregroundStyle(Color.textSoft)
                        .padding(.bottom, 4)
                    ForEach(review.events) { event in
                        Button { toggle(event.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(event.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.ui(22))
                                    .foregroundStyle(selected.contains(event.id) ? Color.accent : Color.textMuted.opacity(0.5))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.serif(15)).foregroundStyle(Color.textPrimary)
                                    Text((event.isAllDay ? "All day" : "\(hhmm(event.startMinute))–\(hhmm(event.endMinute))") + (event.location.isEmpty ? "" : " · \(event.location)"))
                                        .font(.ui(12)).foregroundStyle(Color.textSoft).lineLimit(1)
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

// MARK: - Date jump

/// Reaches any day, which the date dial cannot: it only carries the nearby
/// week. Opened by the header's calendar glyph — the glyph now means what it
/// looks like, instead of silently jumping to a day you were already on.
struct DateJumpSheet: View {
    @Binding var selectedDate: Date
    let today: Date
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Jump to a date").font(.heading(19)).foregroundStyle(Color.textPrimary)
                Spacer()
                Button("Today") {
                    selectedDate = today
                    dismiss()
                }
                .font(.ui(14, weight: .semibold))
                .foregroundStyle(Color.accentDeep)
            }
            .padding(.top, 20).padding(.bottom, 6)

            DatePicker("", selection: $draft, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Color.accent)
                .labelsHidden()

            Button {
                selectedDate = draft.startOfDay
                dismiss()
            } label: {
                Text("Go to \(draft.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                    .font(.ui(14.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bg)
        .onAppear { draft = selectedDate }
    }
}
