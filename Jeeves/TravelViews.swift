//
//  TravelViews.swift
//  Jeeves
//
//  Travel mode's surfaces:
//    • TravelDayCard — what replaces the plan on a travel day. Anchors only.
//    • LeaveByCard — the backward chain, with the assumptions named out loud.
//    • TripEditorView — create a trip and its journeys by hand.
//
//  Every number that is a guess is labelled as one; only the journey time can
//  be measured, and when it hasn't been we say "estimated" rather than implying
//  a precision the app doesn't have.
//

import SwiftUI
import SwiftData

// MARK: - The travel-mode day (replaces "Plan my day")

struct TravelDayCard: View {
    let trip: Trip
    let day: Date
    @Query private var allSegments: [TravelSegment]
    @State private var showTrip = false

    private var segments: [TravelSegment] {
        allSegments
            .filter { $0.tripID == trip.id && Calendar.current.isDate($0.day, inSameDayAs: day) }
            .sorted { ($0.arriveBy ?? $0.departAt) < ($1.arriveBy ?? $1.departAt) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "airplane.departure")
                    .font(.ui(13, weight: .semibold))
                Text("TRAVEL MODE")
                    .font(.ui(11, weight: .bold)).kerning(1.2)
                Spacer()
                Button { showTrip = true } label: {
                    Text(trip.title.isEmpty ? "Trip" : trip.title)
                        .font(.ui(12, weight: .semibold))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Color.travelInk)

            if segments.isEmpty {
                Text("Nothing to catch today.")
                    .font(Font.serif(17))
                    .foregroundStyle(Color.textPrimary)
                Text("You're away, so the planner is standing down — no routine, no gym, no commute. Nothing to be late for.")
                    .font(.ui(12.5))
                    .foregroundStyle(Color.textSoft)
            } else {
                ForEach(segments, id: \.id) { s in
                    LeaveByCard(segment: s)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.travelBg))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.travelInk.opacity(0.22), lineWidth: 1))
        .sheet(isPresented: $showTrip) { TripEditorView(trip: trip) }
    }
}

// MARK: - The leave-by chain

struct LeaveByCard: View {
    let segment: TravelSegment
    @Environment(\.modelContext) private var modelContext
    @State private var pricing = false
    @State private var measureNote: String?

    private var plan: LeaveBy.Plan? { LeaveBy.plan(for: segment) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: segment.mode.icon)
                    .font(.ui(13))
                    .foregroundStyle(Color.travelInk)
                Text(segment.label.isEmpty ? segment.mode.label : segment.label)
                    .font(Font.serif(16, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if !segment.toPlace.isEmpty {
                    Text(segment.toPlace)
                        .font(.ui(11))
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
            }

            if let plan {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("Leave")
                        .font(.ui(12, weight: .semibold))
                        .foregroundStyle(Color.textSoft)
                    // A tilde marks a chain still missing its journey time —
                    // "Leave ~05:30" reads as the estimate it is, not a fact.
                    Text((segment.travelMinutes == 0 ? "~" : "") + hhmm(plan.leaveAt))
                        .font(Font.serif(34, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.travelInk)
                    if chainIsMultiDay {
                        Text(dayTag(plan.leaveAt, in: segment.fromTimeZone))
                            .font(.ui(12, weight: .semibold))
                            .foregroundStyle(Color.travelInk)
                    }
                    if crossesZones {
                        Text(TravelClock.label(segment.fromTimeZone, at: plan.leaveAt))
                            .font(.ui(11, weight: .semibold))
                            .foregroundStyle(Color.textMuted)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .fill(step.isLeave ? Color.travelInk : Color.textMuted.opacity(0.4))
                                .frame(width: step.isLeave ? 8 : 6, height: step.isLeave ? 8 : 6)
                                .padding(.top, 6)
                            // A long drive's chain spans days — "LEAVE 09:20 …
                            // arrive 20:00" read as one morning until each row
                            // carried its date. And a drive's arrival rows live
                            // on the DESTINATION's clock: "Must be there 15:00"
                            // at Thimphu is 15:00 Bhutan time, labelled so.
                            VStack(alignment: .leading, spacing: 0) {
                                Text(TravelClock.hhmm(step.time, in: zone(for: step)))
                                    .font(.ui(13, weight: step.isLeave ? .bold : .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(step.isLeave ? Color.travelInk : Color.textPrimary)
                                if chainIsMultiDay {
                                    Text(dayTag(step.time, in: zone(for: step)))
                                        .font(.ui(9, weight: .semibold))
                                        .foregroundStyle(Color.textMuted)
                                }
                                if driveZonesDiffer {
                                    Text(TravelClock.label(zone(for: step), at: step.time))
                                        .font(.ui(8.5, weight: .semibold))
                                        .foregroundStyle(Color.textMuted)
                                }
                            }
                            .frame(width: 46, alignment: .leading)
                            Text(step.label)
                                .font(.ui(12.5, weight: step.isLeave ? .semibold : .regular))
                                .foregroundStyle(step.isLeave ? Color.travelInk : Color.textSoft)
                            Spacer(minLength: 4)
                            Text(step.detail)
                                .font(.ui(10.5))
                                .foregroundStyle(Color.textMuted)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 3)
                    }

                    // Arrival closes the story — the last thing that happens,
                    // shown on the DESTINATION's clock (and flagged when it
                    // lands on a different calendar day there).
                    if let arriveAt = segment.arriveAt, arriveAt != segment.departAt {
                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .fill(Color.sageDeep)
                                .frame(width: 6, height: 6)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(TravelClock.hhmm(arriveAt, in: segment.toTimeZone))
                                    .font(.ui(13, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.sageDeep)
                                if chainIsMultiDay {
                                    Text(dayTag(arriveAt, in: segment.toTimeZone))
                                        .font(.ui(9, weight: .semibold))
                                        .foregroundStyle(Color.textMuted)
                                }
                            }
                            .frame(width: 46, alignment: .leading)
                            Text("Arrives")
                                .font(.ui(12.5, weight: .semibold))
                                .foregroundStyle(Color.sageDeep)
                            if TravelClock.crossesDay(departure: segment.departAt,
                                                      departureZone: segment.fromTimeZone,
                                                      arrival: arriveAt, arrivalZone: segment.toTimeZone) {
                                Text("next day")
                                    .font(.ui(9.5, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accent.opacity(0.18)))
                                    .foregroundStyle(Color.accentDeep)
                            }
                            Spacer(minLength: 4)
                            Text(TravelClock.label(segment.toTimeZone, at: arriveAt)
                                 + (TravelClock.offsetLabel(from: segment.fromTimeZone,
                                                            to: segment.toTimeZone,
                                                            at: arriveAt).map { " \u{00B7} clock \($0)" } ?? ""))
                                .font(.ui(10.5))
                                .foregroundStyle(Color.textMuted)
                        }
                        .padding(.vertical, 3)
                    }
                }

                Text(segment.travelMinutes == 0
                     ? (segment.mode == .drive
                        ? "No journey time yet — this chain is missing the drive itself. Add the route and I'll redo it; no nudge until then."
                        : "No airport run yet — this chain budgets zero minutes to the terminal. Add the airport in the To field and I'll redo it; no nudge until then.")
                     : plan.travelIsEstimated
                     ? "Journey time is an estimate — tap Measure to price it against live traffic. Cut-off, security and buffer are always your assumptions."
                     : freshnessNote)
                    .font(.ui(10.5))
                    .foregroundStyle(segment.travelMinutes == 0 ? Color.accentDeep : Color.textMuted)
                    .padding(.top, 2)

                // Nobody chose this mode — the calendar picked it, and the same
                // default calls Bali → Singapore a drive. Saying so is the
                // difference between an assumption and a claim.
                if segment.modeIsAssumed {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "questionmark.circle").font(.ui(10))
                        // When the road has refuted it, say what it said. "I've
                        // assumed you're driving" alone tells you there is a
                        // doubt; it does not tell you the Java Sea is in the way.
                        Text(segment.modeRefutation.isEmpty
                             ? "I've assumed you're driving. Tap Measure, or set the mode yourself."
                             : segment.modeRefutation)
                            .font(.ui(10.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Color.accentDeep)
                    .padding(.top, 1)
                }

                if !segment.toPlace.isEmpty {
                    Button { measure() } label: {
                        HStack(spacing: 6) {
                            if pricing { ProgressView().scaleEffect(0.6) }
                            Image(systemName: "location.fill").font(.ui(10))
                            Text(pricing ? "Measuring…" : "Measure the journey")
                                .font(.ui(12, weight: .semibold))
                        }
                        .foregroundStyle(Color.travelInk)
                        .padding(.vertical, 8).frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.travelInk.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .disabled(pricing)
                }
                if let measureNote {
                    Text(measureNote)
                        .font(.ui(10.5))
                        .foregroundStyle(Color.accentDeep)
                        .padding(.top, 2)
                }
            } else {
                Text(segment.mode == .drive
                     ? "Add the time you must arrive and I'll work backwards."
                     : "Add the departure time and I'll work backwards.")
                    .font(.ui(12.5))
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
    }

    /// Price the real journey with live traffic, from wherever this leg starts
    /// (Home, or the hotel you're actually in).
    private func measure() {
        pricing = true
        measureNote = nil
        let from = segment.fromPlace
        let to = segment.toPlace
        let target = LeaveBy.plan(for: segment)?.leaveAt ?? Date()
        Task {
            guard let origin = await resolvedOrigin(from) else {
                measureNote = from.isEmpty && startsFromAnEarlierStay
                    ? "I don't know where this starts — the stay before it has no address yet. Add one and I'll measure the drive."
                    : RoutableOrigin.missingHomeMessage
                pricing = false
                return
            }
            // A flight's door-to-terminal slot is checked first and separately:
            // days of road time there means To isn't an airport at all, which
            // is a different mistake from a transfer that isn't a drive.
            if segment.mode != .drive,
               let minutes = await GoogleMapsService.commuteMinutes(from: origin, to: to,
                                                                    departure: max(target, Date())),
               minutes > 360 {
                measureNote = "That routes \(LeaveBy.hours(minutes)) by road — the To field should be the departure airport, not a city or home."
                pricing = false
                return
            }
            // Everything else goes through the one funnel, so tapping Measure
            // can no longer settle a mode the road refuses to support, nor
            // leave a stale refutation standing, nor forget the timestamp.
            let ends = JourneyMeasurement.endpoints(of: segment.label,
                                                    fallbackFrom: origin, fallbackTo: to)
            let decision = await JourneyMeasurement.apply(
                to: segment, from: origin, to: to,
                departure: max(target, Date()), label: ends)
            measureNote = decision.note
            modelContext.saveOrLog("LeaveByCard.measure")
            if decision.mayNudge {
                // A newly real journey time can move the leave-by day outside
                // the trip — grow the window so the card doesn't relocate
                // itself into invisibility.
                await TravelGuard.absorb(segment, context: modelContext)
                await TravelNotifier.schedule(segment: segment)
            }
            pricing = false
        }
    }

    /// "Home"/"Work"/"Gym" resolve to their saved addresses; anything else is
    /// already a place. nil when the result would still be a label rather than
    /// somewhere a routing API can start — the old code returned the word
    /// "Home" and let Google geocode it to whatever it fancied.
    private func resolvedOrigin(_ raw: String) async -> String? {
        let saved = (try? modelContext.fetch(FetchDescriptor<SavedLocation>())) ?? []
        if raw.isEmpty {
            // Home is the right default for the journey that LEAVES home. It is
            // the wrong one for a hotel-to-hotel transfer whose first hotel has
            // no address yet: that measured Bengaluru → Bandipur and stored it
            // as the Kabini → Bandipur drive, as a measured fact.
            if startsFromAnEarlierStay { return nil }
            return RoutableOrigin.address(saved.first { $0.kind == .home }?.address)
        }
        if let match = saved.first(where: { $0.kind.rawValue.lowercased() == raw.lowercased() }) {
            return RoutableOrigin.address(match.address.isEmpty ? raw : match.address)
        }
        return RoutableOrigin.address(raw)
    }

    /// Does a stay end on or before this journey's day? If so, an empty From
    /// means "that stay", not "home" — and since the stay has no address, the
    /// honest answer is that we don't know where this starts.
    private var startsFromAnEarlierStay: Bool {
        guard let stays = try? modelContext.fetch(FetchDescriptor<TripStay>()) else { return false }
        let day = Calendar.current.startOfDay(for: segment.day)
        return stays.contains {
            $0.tripID == segment.tripID
                && Calendar.current.startOfDay(for: $0.arriveDate) < day
        }
    }

    /// "Measured" was one word for two very different things: a traffic
    /// PREDICTION for a departure a fortnight out, and a reading taken minutes
    /// ago. Only the second should let a leave-by stand unquestioned.
    private var freshnessNote: String {
        switch segment.freshness() {
        case .never:
            return "Journey measured against live traffic. Cut-off, security and buffer are your assumptions."
        case .predicted(let days):
            return "Journey time is Google's forecast for that time of day, taken \(days) day\(days == 1 ? "" : "s") ahead — not a road anyone has driven yet. Re-measure nearer the day."
        case .live(let age):
            return age < 60
                ? "Journey measured against live traffic just now. Cut-off, security and buffer are your assumptions."
                : "Journey measured against live traffic \(LeaveBy.hours(age)) ago. Cut-off, security and buffer are your assumptions."
        }
    }

    /// Every step of the chain happens where the journey STARTS, so the whole
    /// countdown is read on that clock — the one you're actually looking at.
    private func hhmm(_ d: Date) -> String {
        TravelClock.hhmm(d, in: segment.fromTimeZone)
    }

    private var crossesZones: Bool {
        // Offsets only: the editor now auto-fills zone IDs for every journey,
        // so "an ID is set" no longer implies a cross-zone trip — a domestic
        // Bhadra drive would have sprouted a spurious IST chip.
        segment.fromTimeZone.secondsFromGMT(for: segment.departAt)
            != segment.toTimeZone.secondsFromGMT(for: segment.departAt)
    }

    /// A drive's LEAVE happens on the origin's clock; every later row —
    /// planned arrival, the deadline — lives at the destination. A flight's
    /// whole chain (terminal, cut-off, departure) runs at the origin airport;
    /// only its separate Arrives row uses the destination clock.
    private func zone(for step: LeaveBy.Step) -> TimeZone {
        segment.mode == .drive && !step.isLeave ? segment.toTimeZone : segment.fromTimeZone
    }

    private var driveZonesDiffer: Bool {
        guard segment.mode == .drive else { return false }
        let at = segment.arriveBy ?? Date()
        return segment.fromTimeZone.secondsFromGMT(for: at) != segment.toTimeZone.secondsFromGMT(for: at)
    }

    /// True when the chain doesn't fit in one calendar day — judged on the
    /// clock EACH ROW RENDERS IN (a drive can stay same-day at the origin yet
    /// cross midnight on the destination clock its deadline is shown in).
    private var chainIsMultiDay: Bool {
        guard let plan, let first = plan.steps.first else { return false }
        func ymd(_ t: Date, _ z: TimeZone) -> DateComponents {
            var c = Calendar.current
            c.timeZone = z
            return c.dateComponents([.year, .month, .day], from: t)
        }
        let base = ymd(first.time, zone(for: first))
        var rows: [(Date, TimeZone)] = plan.steps.map { ($0.time, zone(for: $0)) }
        if let a = segment.arriveAt { rows.append((a, segment.toTimeZone)) }
        return rows.contains { ymd($0.0, $0.1) != base }
    }

    private func dayTag(_ d: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        f.timeZone = zone
        return f.string(from: d)
    }
}

// MARK: - Quiet travel day

/// One card for every covering trip that has NO journey today — instead of a
/// stack of identical "Nothing to catch today" boxes (three, when the legacy
/// overlapping Bali trips all covered the same day). Trips with journeys get
/// their own TravelDayCard above this one; this is only the quiet remainder.
struct TravelQuietDayCard: View {
    let trips: [Trip]
    var onOpen: (Trip) -> Void = { _ in }

    /// Two of today's trips genuinely overlapping (more than a shared
    /// boundary day) means duplicate data, not a handover — say so, and say
    /// the fix.
    private var hasInteriorOverlap: Bool {
        guard trips.count > 1 else { return false }
        for i in trips.indices {
            for j in trips.indices where j > i {
                if trips[i].endDate > trips[j].startDate && trips[j].endDate > trips[i].startDate {
                    return true
                }
            }
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "airplane.departure")
                    .font(.ui(13))
                    .foregroundStyle(Color.travelInk)
                Text("TRAVEL MODE")
                    .font(.ui(12, weight: .bold)).kerning(1.5)
                    .foregroundStyle(Color.travelInk)
                Spacer()
            }
            Text("Nothing to catch today.")
                .font(Font.serif(26, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("You're away, so the planner is standing down — no routine, no gym, no commute. Nothing to be late for.")
                .font(.ui(14))
                .foregroundStyle(Color.textSoft)

            // Every trip owning this day, each a link into its editor.
            HStack(spacing: 8) {
                ForEach(trips, id: \.id) { trip in
                    Button { onOpen(trip) } label: {
                        Text(trip.title.isEmpty ? "Trip" : trip.title)
                            .font(.ui(12, weight: .semibold))
                            .underline()
                            .foregroundStyle(Color.travelInk)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)

            if hasInteriorOverlap {
                Text("These trips overlap — that's duplicate data, not a handover. Say \u{201C}clean up my travel data\u{201D} in Jeeves chat and they'll merge, with a receipt.")
                    .font(.ui(11.5))
                    .foregroundStyle(Color.accentDeep)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.travelBg))
    }
}

// MARK: - Trip editor

struct TripEditorView: View {
    let trip: Trip
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allSegments: [TravelSegment]
    @Query private var allStays: [TripStay]

    @State private var editing: TravelSegment?
    // Segments minted this session by the add buttons: dismissing their
    // editor without saving discards them.
    @State private var freshIDs = Set<UUID>()
    @State private var confirmingDelete = false

    private var segments: [TravelSegment] {
        allSegments.filter { $0.tripID == trip.id }
            .sorted { ($0.arriveBy ?? $0.departAt) < ($1.arriveBy ?? $1.departAt) }
    }

    private var stayRows: [TripStay] {
        allStays.filter { $0.tripID == trip.id }
            .sorted { $0.arriveDate < $1.arriveDate }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        stat("Days", "\(trip.dayCount)")
                        stat("Journeys", "\(segments.count)")
                    }

                    // The dates are editable: a trip's window often has to grow —
                    // a two-day return drive lands after the calendar event ends.
                    HStack(spacing: 10) {
                        dateBox("Starts", get: { trip.startDate }, set: { setDates(start: $0) })
                        dateBox("Ends", get: { trip.endDate }, set: { setDates(end: $0) })
                    }

                    Text("The planner stands down for every day of this trip. What you get instead are the journeys below.")
                        .font(.ui(12))
                        .foregroundStyle(Color.textMuted)
                        .padding(.bottom, 2)

                    // A trip with no journeys silently computes nothing — ask the
                    // one question that matters instead of showing "Journeys: 0".
                    if segments.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("How are you getting there — and home?")
                                .font(.ui(14, weight: .semibold))
                                .foregroundStyle(Color.travelInk)
                            Text("Add the outbound and the return below, and I'll work out when to leave for each — including the way home.")
                                .font(.ui(12))
                                .foregroundStyle(Color.textSoft)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Color.travelInk.opacity(0.08)))
                    }

                    // Where you sleep. The editor listed journeys and never the
                    // stays, so a trip built from a calendar showed its flights
                    // and kept its hotels invisible — and a nights count that
                    // was wrong by one had nowhere to be noticed.
                    if !stayRows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("WHERE YOU'RE STAYING")
                                .font(.ui(10.5, weight: .bold)).kerning(1.1)
                                .foregroundStyle(Color.travelInk)
                            ForEach(stayRows, id: \.id) { st in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(st.place.isEmpty ? "Somewhere" : st.place)
                                            .font(Font.serif(15, weight: .semibold))
                                            .foregroundStyle(Color.textPrimary)
                                        Spacer(minLength: 4)
                                        Text(st.nightsText())
                                            .font(.ui(11.5, weight: .semibold))
                                            .foregroundStyle(st.endIsUnsettled ? Color.accentDeep : Color.textSoft)
                                    }
                                    Text(st.address.isEmpty ? "No address yet — no drive, no leave-by."
                                                            : st.address)
                                        .font(.ui(10.5))
                                        .foregroundStyle(st.address.isEmpty ? Color.accentDeep : Color.textMuted)
                                        .lineLimit(2)
                                    if st.endIsUnsettled {
                                        // The calendar cannot say whether its last
                                        // day is a night here or the morning you go.
                                        Text("Your calendar doesn't say whether the last day is a night here or the day you leave.")
                                            .font(.ui(10))
                                            .foregroundStyle(Color.accentDeep)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Color.surface))
                    }

                    ForEach(segments, id: \.id) { s in
                        // NOT a Button wrapping the card: LeaveByCard has its
                        // own "Measure the journey" button inside it, and a
                        // Button nested in another Button's label lets the
                        // outer one swallow the tap — Measure would silently
                        // open the editor instead of measuring. A tap gesture
                        // on the card yields to the inner button, so both work.
                        LeaveByCard(segment: s)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = s }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Opens this journey's details")
                    }

                    Button { editing = newSegment(.flight) } label: {
                        addLabel("Add a flight", "airplane")
                    }
                    .buttonStyle(.plain)
                    Button { editing = newSegment(.drive) } label: {
                        addLabel("Add a drive", "car.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
            .background(Color.bg)
            .navigationTitle(trip.title.isEmpty ? "Trip" : trip.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Deleting a trip takes its stays and journeys with it and
                    // hands the days back to the planner. Chat confirms and
                    // issues a receipt for exactly this operation; the UI used
                    // to do it on one unlabelled tap with no way back.
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .tint(Color.accentDeep)
                    .accessibilityLabel("Delete trip")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(Color.accentDeep)
                }
            }
            .sheet(item: $editing) { SegmentEditorView(segment: $0, isNew: freshIDs.contains($0.id)) }
            // Name the blast radius in the message rather than asking a bare
            // "are you sure?" — the counts are what make the choice.
            .confirmationDialog("Delete this trip?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete trip and \(segments.count) journey\(segments.count == 1 ? "" : "s")",
                       role: .destructive) { deleteTrip() }
                Button("Keep it", role: .cancel) { }
            } message: {
                Text("\(trip.dayCount) day\(trip.dayCount == 1 ? "" : "s") go back to the normal planner, and every leave-by nudge for this trip is cancelled. This can't be undone.")
            }
        }
    }

    private func newSegment(_ mode: TravelMode) -> TravelSegment {
        let cal = Calendar.current
        // The first journey is the way OUT; once one exists, the next is almost
        // always the way HOME. Prefill each honestly from what the calendar and
        // saved locations already know — and never guess what we don't: a
        // flight's "To" is the departure airport, which no stay can tell us, so
        // it stays empty rather than pointing the route at a hotel abroad.
        let isReturn = !segments.isEmpty
        let stays = ((try? modelContext.fetch(FetchDescriptor<TripStay>())) ?? [])
            .sorted { $0.arriveDate < $1.arriveDate }
        let tripStays = stays.filter { $0.tripID == trip.id }
        let prior = stays
            .filter { s in !tripStays.contains { $0.id == s.id } && s.departDate <= trip.startDate }
            .max { $0.departDate < $1.departDate }
        func addr(_ s: TripStay?) -> String? { s.map { $0.address.isEmpty ? $0.place : $0.address } }
        let (fromPlace, toPlace) = JourneyPrefill.places(
            mode: mode, isReturn: isReturn, home: homeAddress(),
            lastStay: addr(tripStays.max { $0.departDate < $1.departDate }),
            firstStay: addr(tripStays.first),
            priorStay: addr(prior))

        // Outbound anchors to the trip's first day, the return to its last.
        let anchorDay = isReturn ? trip.endDate : trip.startDate
        let anchorHour = isReturn && mode == .drive ? 18 : 9
        let anchor = cal.date(bySettingHour: anchorHour, minute: 0, second: 0, of: anchorDay) ?? anchorDay

        let s = TravelSegment(tripID: trip.id, mode: mode,
                              label: mode == .flight ? "" : (isReturn ? "Drive home" : "Drive"),
                              fromPlace: fromPlace,
                              toPlace: toPlace,
                              departAt: mode == .flight ? anchor : .distantPast,
                              arriveBy: mode == .drive ? anchor : nil,
                              checkInMinutes: mode == .flight ? 180 : 0,
                              securityMinutes: mode == .flight ? 30 : 0)
        modelContext.insert(s)
        modelContext.saveOrLog("TripEditor.newSegment")
        freshIDs.insert(s.id)
        return s
    }

    /// The saved Home address, or empty — never an invented place.
    private func homeAddress() -> String {
        let saved = (try? modelContext.fetch(FetchDescriptor<SavedLocation>())) ?? []
        return saved.first { $0.kind == .home }.map(\.address) ?? ""
    }

    private func setDates(start: Date? = nil, end: Date? = nil) {
        if let start { trip.startDate = start.startOfDay }
        if let end { trip.endDate = end.startOfDay }
        if trip.endDate < trip.startDate {
            if start != nil { trip.endDate = trip.startDate } else { trip.startDate = trip.endDate }
        }
        modelContext.saveOrLog("TripEditor.setDates")
        // Newly covered days may hold stale plans — the trip owns them now.
        Task { await TravelGuard.sweep(context: modelContext) }
    }

    private func dateBox(_ title: String, get: @escaping () -> Date, set: @escaping (Date) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.ui(10, weight: .bold)).kerning(0.8)
                .foregroundStyle(Color.textMuted)
            DatePicker("", selection: Binding(get: get, set: set), displayedComponents: [.date])
                .labelsHidden()
                .font(.ui(13))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.surface))
    }

    private func deleteTrip() {
        for s in allSegments where s.tripID == trip.id {
            TravelNotifier.cancel(segment: s)
            modelContext.delete(s)
        }
        let stays = (try? modelContext.fetch(FetchDescriptor<TripStay>())) ?? []
        for st in stays where st.tripID == trip.id { modelContext.delete(st) }
        modelContext.delete(trip)
        modelContext.saveOrLog("TripEditor.deleteTrip")
        dismiss()
    }

    private func addLabel(_ t: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.ui(13))
            Text(t).font(.ui(14.5, weight: .semibold))
        }
        .foregroundStyle(Color.travelInk)
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .overlay(RoundedRectangle(cornerRadius: 13)
            .strokeBorder(Color.travelInk.opacity(0.4), style: StrokeStyle(lineWidth: 1.3, dash: [5])))
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(.ui(10, weight: .bold)).kerning(0.8)
                .foregroundStyle(Color.textMuted)
            Text(v).font(Font.serif(18, weight: .semibold)).foregroundStyle(Color.textPrimary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.surface))
    }
}

// MARK: - Segment editor

struct SegmentEditorView: View {
    let segment: TravelSegment
    /// True when the trip editor just minted this segment: dismissing without
    /// saving then deletes it, so a half-configured shell never lingers in
    /// the trip (the old behavior persisted every "Add a flight" tap forever).
    var isNew: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var from = ""
    @State private var to = ""
    @State private var when = Date()
    @State private var checkIn = 180
    @State private var security = 30
    @State private var buffer = 20
    @State private var stops = 0
    @State private var travel = 0
    @State private var loaded = false
    @State private var confirmingDelete = false
    @State private var arrives = Date()
    @State private var fromZoneID = ""
    @State private var toZoneID = ""
    // A counter, not a Bool: two zone lookups can run at once (origin and
    // destination) and a shared flag reported "done" when the first landed.
    @State private var zoneLookups = 0
    private var lookingUpZone: Bool { zoneLookups > 0 }
    @State private var measuring = false
    @State private var measureFailed = false
    @State private var travelMeasured = false
    // A "successful" measurement can still be nonsense — a flight's To
    // pointing at a city routes days of road time into the door-to-terminal
    // slot. Anything over 6 h is refused, not stored.
    @State private var implausibleMinutes = 0
    // What the arrival picker held when the sheet opened; an arrival is only
    // stored if the user actually moved it (or one was already stored) —
    // otherwise editing just the departure used to freeze a phantom arrival.
    @State private var loadedArrives = Date.distantPast
    // What the main picker held when the sheet opened (or was last re-rendered
    // by an arriving zone) — the marker for "the user hasn't touched this".
    @State private var loadedWhen = Date.distantPast
    // Where the place fields started, so programmatic assignment in load()
    // never triggers the edit-driven zone re-lookup.
    @State private var loadedFrom = ""
    @State private var loadedTo = ""
    @State private var zoneRelookup: Task<Void, Never>?
    @State private var saveError: String?
    @State private var didSave = false
    @State private var didDelete = false

    private var isFlight: Bool { segment.mode != .drive }
    /// The clock the main time picker is read on: a flight departs on the
    /// origin's clock, but a drive's "must arrive by" lives at the DESTINATION
    /// — "arrive 15:00" means 15:00 where you're going.
    private var deadlineZoneID: String { isFlight ? fromZoneID : toZoneID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    field("Name", text: $label, placeholder: isFlight ? "6E 1605" : "Drive to Bhadra")
                    // From/To are the two ends of the JOURNEY — for a flight
                    // that's door to departure airport, and the labels say so,
                    // because prefilling a hotel abroad once measured a 40-hour
                    // road route to Kathmandu. A flight's To never offers the
                    // Home chip: home is the one place you can't fly from.
                    field("From — where you set off", text: $from,
                          placeholder: "Home — or a hotel address", homeChip: true)
                    field(isFlight ? "To — the airport you fly from" : "To — your destination",
                          text: $to, placeholder: isFlight ? "BLR airport" : "JLR River Tern Lodge",
                          homeChip: !isFlight)

                    DatePicker(isFlight ? "Departs" : "Must arrive by",
                               selection: $when, displayedComponents: [.date, .hourAndMinute])
                        .font(.ui(14))
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))

                    // The clock the time above is read on. Getting this wrong is
                    // the difference between making a flight and missing it, so
                    // it's stated rather than assumed — and auto-filled from the
                    // place on open, because a silently wrong default zone made
                    // every Bhutan deadline 30 minutes late.
                    if isFlight {
                        zoneRow("Time is local to", $fromZoneID, place: from.isEmpty ? "Home" : from)
                    } else {
                        zoneRow("Deadline is local to", $toZoneID, place: to)
                    }
                    if isFlight {
                        DatePicker("Arrives", selection: $arrives,
                                   displayedComponents: [.date, .hourAndMinute])
                            .font(.ui(14))
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
                        zoneRow("Arrival clock", $toZoneID, place: to)
                        if let off = TravelClock.offsetLabel(from: zone(fromZoneID), to: zone(toZoneID),
                                                             at: Date()) {
                            Text("Destination clock is \(off) from where you leave.")
                                .font(.ui(11)).foregroundStyle(Color.textMuted)
                        }
                    }

                    Text("ASSUMPTIONS — CORRECT THEM ONCE")
                        .font(.ui(10, weight: .bold)).kerning(1)
                        .foregroundStyle(Color.textMuted).padding(.top, 6)

                    if isFlight {
                        stepper("Airline cut-off", $checkIn, step: 30, unit: "min")
                        stepper("Immigration & security", $security, step: 5, unit: "min")
                    } else {
                        stepper("Stops on route", $stops, step: 5, unit: "min")
                    }
                    stepper("Your own buffer", $buffer, step: 5, unit: "min")

                    // Journey time is MEASURED, never asked for. It only turns
                    // into a question when Maps genuinely can't find the place.
                    journeyRow

                    if let saveError {
                        Text(saveError)
                            .font(.ui(12, weight: .medium))
                            .foregroundStyle(Color.accentDeep)
                    }
                }
                .padding(18)
            }
            .background(Color.bg)
            .navigationTitle(isFlight ? "Flight" : "Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .tint(Color.accentDeep)
                    .accessibilityLabel(isFlight ? "Delete flight" : "Delete drive")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Saving mid-lookup stored an empty zone or a zero journey
                    // and let the async result land in a dismissed sheet.
                    Button("Save") { save() }.tint(Color.accentDeep)
                        .disabled(measuring || zoneLookups > 0)
                }
            }
            .onAppear(perform: load)
            .confirmationDialog("Delete this \(isFlight ? "flight" : "drive")?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    // A deleted journey must take its leave-by nudge with
                    // it — a cancelled trip still fired 3 a.m. reminders.
                    didDelete = true
                    TravelNotifier.cancel(segment: segment)
                    modelContext.delete(segment)
                    modelContext.saveOrLog("SegmentEditor.delete")
                    dismiss()
                }
                Button("Keep it", role: .cancel) { }
            } message: {
                Text("Its leave-by nudge is cancelled with it. This can't be undone.")
            }
            .onDisappear {
                // Swiping away a freshly minted segment abandons it — take it
                // back out rather than leaving a shell in the trip.
                if isNew && !didSave && !didDelete {
                    TravelNotifier.cancel(segment: segment)
                    modelContext.delete(segment)
                    modelContext.saveOrLog("SegmentEditor.discardNew")
                }
            }
            .onChange(of: from) { _, newValue in
                if newValue != loadedFrom { scheduleZoneRelookup(newValue, into: $fromZoneID) }
            }
            .onChange(of: to) { _, newValue in
                if !isFlight, newValue != loadedTo { scheduleZoneRelookup(newValue, into: $toZoneID) }
            }
        }
    }

    /// A changed place means the old zone may be wrong — re-look it up once
    /// typing pauses. The Kathmandu scenario showed the chain running 15
    /// minutes late because editing From never refreshed the zone and the
    /// user was expected to know to tap Find.
    private func scheduleZoneRelookup(_ place: String, into binding: Binding<String>) {
        zoneRelookup?.cancel()
        let trimmed = place.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        zoneRelookup = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            lookUpZone(for: trimmed, into: binding)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        label = segment.label; from = segment.fromPlace; to = segment.toPlace
        loadedFrom = from; loadedTo = to
        fromZoneID = segment.fromTimeZoneID; toZoneID = segment.toTimeZoneID
        // Show stored instants as the wall-clock they read on their own zone,
        // so opening and saving without edits changes nothing.
        let stored = isFlight ? (segment.departAt == .distantPast ? nil : segment.departAt)
                              : segment.arriveBy
        when = stored.map { TravelClock.wallClock(of: $0, in: zone(deadlineZoneID)) } ?? Date()
        arrives = segment.arriveAt.map { TravelClock.wallClock(of: $0, in: zone(toZoneID)) } ?? when
        loadedArrives = arrives
        loadedWhen = when
        checkIn = segment.checkInMinutes; security = segment.securityMinutes
        buffer = segment.bufferMinutes; stops = segment.stopMinutes; travel = segment.travelMinutes
        travelMeasured = !segment.travelIsEstimated
        // Zones are looked up from the places on open, never assumed: the
        // device clock as a silent default made a 15:00 Thimphu deadline store
        // as 15:00 IST — thirty minutes late. (A flight's arrival clock stays
        // manual: the To field is the departure airport, so it can't tell us
        // where the flight lands.)
        if fromZoneID.isEmpty, !from.isEmpty { lookUpZone(for: from, into: $fromZoneID) }
        if !isFlight, toZoneID.isEmpty, !to.isEmpty { lookUpZone(for: to, into: $toZoneID) }
        // Nothing measured yet but we know where we're going — do it now rather
        // than making the user type a distance.
        if travel == 0, !to.isEmpty { measureJourney() }
    }

    private func save() {
        // The >6 h rule holds at the door too: the measure refusing a road
        // route means nothing if Save then stores the override anyway.
        if isFlight && !LeaveBy.plausibleFlightJourney(travel) {
            saveError = "\(LeaveBy.hours(travel)) by road isn't a door-to-airport run — fix the To field (the airport you fly from), or add this leg as a drive."
            return
        }
        saveError = nil
        didSave = true
        segment.label = label
        segment.fromPlace = from
        segment.toPlace = to
        segment.fromTimeZoneID = fromZoneID
        segment.toTimeZoneID = toZoneID
        // Read the typed wall-clock on the journey's own clock, not the phone's
        // — the origin's for a flight departure, the DESTINATION's for a
        // drive's arrival deadline.
        let departInstant = TravelClock.instant(readingWallClock: when, in: zone(deadlineZoneID))
        if isFlight {
            segment.departAt = departInstant
            segment.arriveBy = nil
            // An arrival is stored only if the user moved the picker (or one
            // was already stored): the untouched picker just echoes whatever
            // the sheet opened with, and storing that froze phantom arrivals —
            // including ones BEFORE departure once only the departure was
            // edited. Equality with departure still means "not set".
            let arrivesTouched = arrives != loadedArrives || segment.arriveAt != nil
            let arriveInstant = TravelClock.instant(readingWallClock: arrives, in: zone(toZoneID))
            segment.arriveAt = (arrivesTouched && arriveInstant != departInstant) ? arriveInstant : nil
        } else {
            segment.arriveBy = departInstant
            segment.arriveAt = nil
        }
        segment.checkInMinutes = checkIn
        segment.securityMinutes = security
        segment.bufferMinutes = buffer
        segment.stopMinutes = stops
        // The sixth direct write, and the one that made freshness lie: saving a
        // measured value here never stamped `measuredAt`, so a reading taken
        // by this editor rendered as "measured against live traffic" for ever
        // with no age behind it. A hand-typed number is still not measured.
        if travelMeasured, travel != segment.travelMinutes || segment.measuredAt == nil {
            segment.record(minutes: travel, settlesMode: false)
        } else {
            segment.travelMinutes = travel
            segment.travelIsEstimated = !travelMeasured
            if !travelMeasured { segment.measuredAt = nil }   // typed, not measured
        }
        // The user has just told us what this journey is; a refutation of the
        // mode we guessed no longer describes anything.
        if !segment.modeIsAssumed { segment.modeRefutation = "" }
        modelContext.saveOrLog("SegmentEditor.save")
        EventLog.log(.journeySaved,
                     "\(label.isEmpty ? segment.mode.label : label) — \(travel) min journey"
                     + (travelMeasured ? " (measured)" : " (unmeasured)"),
                     subject: segment.id, context: modelContext)
        extendTripIfNeeded()
        Task { await TravelNotifier.schedule(segment: segment) }
        dismiss()
    }

    /// A journey that leaves before the trip starts or lands after it ends
    /// grows the trip to match — days you're on the road are trip days, and
    /// the planner must stand down on them too. Shared with the card's
    /// Measure and chat's add_journey via TravelGuard.absorb, so no surface
    /// can leave a journey stranded outside its trip's window.
    private func extendTripIfNeeded() {
        Task { await TravelGuard.absorb(segment, context: modelContext) }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String,
                       homeChip: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.ui(10, weight: .bold)).kerning(0.8)
                .foregroundStyle(Color.textMuted)
            HStack(spacing: 6) {
                TextField(placeholder, text: text)
                    .font(.ui(15))
                // One tap for the place the app already knows. Only offered
                // when a Home address is actually saved — never an invented one.
                if homeChip, text.wrappedValue.isEmpty, !homeAddress.isEmpty {
                    Button { text.wrappedValue = homeAddress } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "house.fill").font(.ui(9))
                            Text("Home").font(.ui(11.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.travelInk)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(Color.travelInk.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.surface))
        }
    }

    private var homeAddress: String {
        let saved = (try? modelContext.fetch(FetchDescriptor<SavedLocation>())) ?? []
        return saved.first { $0.kind == .home }.map(\.address) ?? ""
    }

    /// How long the journey takes is Google's job, not the user's. This row
    /// measures it on its own; the manual stepper only appears when the lookup
    /// fails, and says why.
    @ViewBuilder
    private var journeyRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("JOURNEY TIME").font(.ui(9.5, weight: .bold)).kerning(0.7)
                        .foregroundStyle(Color.textMuted)
                    if measuring {
                        Text("Measuring against live traffic\u{2026}")
                            .font(.ui(13)).foregroundStyle(Color.textSoft)
                    } else if travel > 0 {
                        Text(LeaveBy.hours(travel)
                             + (travelMeasured ? " \u{00B7} live traffic" : " \u{00B7} entered by you"))
                            .font(.ui(14, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                    } else if implausibleMinutes > 0 {
                        Text("That routes \(LeaveBy.hours(implausibleMinutes)) by road")
                            .font(.ui(13, weight: .medium))
                            .foregroundStyle(Color.accentDeep)
                    } else if measureFailed {
                        Text("Couldn't find that place")
                            .font(.ui(13, weight: .medium))
                            .foregroundStyle(Color.accentDeep)
                    } else {
                        Text("Add a destination and I'll measure it")
                            .font(.ui(13)).foregroundStyle(Color.textMuted)
                    }
                }
                Spacer(minLength: 6)
                if measuring { ProgressView().scaleEffect(0.6) }
                else if !to.isEmpty {
                    Button { measureJourney() } label: {
                        Text(travel > 0 ? "Re-measure" : "Measure")
                            .font(.ui(12, weight: .semibold))
                            .foregroundStyle(Color.travelInk)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Capsule().fill(Color.travelInk.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))

            // Only ask once the automatic route has actually failed or refused.
            if measureFailed || implausibleMinutes > 0 || (travel > 0 && !travelMeasured) {
                // Hand-entered minutes are the user's estimate, never "live
                // traffic" — moving the stepper clears the measured flag.
                stepper("Override", Binding(get: { travel },
                                            set: { travel = $0; travelMeasured = false }),
                        step: 15, unit: "min")
                Text(implausibleMinutes > 0
                     ? "A flight's journey is door to departure airport — \u{201C}\(to)\u{201D} doesn't look like one. Fix the To field, or give me the real airport-run minutes."
                     : measureFailed
                     ? "I couldn't route to \u{201C}\(to)\u{201D} — give me a rough number and I'll work backwards from it."
                     : "Using your number. Tap Measure to price the real route instead.")
                    .font(.ui(11)).foregroundStyle(Color.textMuted)
            }
        }
    }

    /// Price the route now, from wherever this leg starts.
    private func measureJourney() {
        guard !to.isEmpty else { return }
        measuring = true
        measureFailed = false
        implausibleMinutes = 0
        let originRaw = from.isEmpty ? "Home" : from
        Task {
            let saved = (try? modelContext.fetch(FetchDescriptor<SavedLocation>())) ?? []
            let resolved = saved.first { $0.kind.rawValue.lowercased() == originRaw.lowercased() }
                .map(\.address).flatMap { $0.isEmpty ? nil : $0 } ?? originRaw
            // This editor measures the moment it opens, so an unresolved label
            // went to Google unprompted and came back as a leave-by nobody
            // asked for. A word is not somewhere to start from.
            guard let origin = RoutableOrigin.address(resolved) else {
                measureFailed = true
                measuring = false
                return
            }
            if let m = await GoogleMapsService.commuteMinutes(from: origin, to: to,
                                                             departure: max(when, Date())) {
                // A flight's journey is door-to-terminal. Days of road time
                // mean the To field is a city or a house, not an airport —
                // refuse the number instead of confidently scheduling a
                // leave-by two days early.
                if isFlight && m > 360 {
                    implausibleMinutes = m
                    // The stale previous measurement must die with the refusal
                    // — otherwise Save stored the OLD airport's minutes as
                    // "live traffic" against the new, unmeasured To.
                    travel = 0
                    travelMeasured = false
                } else {
                    travel = m
                    travelMeasured = true
                    implausibleMinutes = 0
                }
            } else {
                measureFailed = true
            }
            measuring = false
        }
    }

    private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id) ?? .current }

    /// Pick the clock a time is read on. Auto-filled by geocoding the place, so
    /// in practice the user rarely touches it — but it's always visible, because
    /// a silent wrong zone is a missed flight.
    private func zoneRow(_ title: String, _ binding: Binding<String>, place: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased()).font(.ui(9.5, weight: .bold)).kerning(0.7)
                    .foregroundStyle(Color.textMuted)
                Text(binding.wrappedValue.isEmpty
                     ? "This phone (\(TravelClock.label(.current)))"
                     : "\(binding.wrappedValue) (\(TravelClock.label(zone(binding.wrappedValue))))")
                    .font(.ui(13, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if !place.isEmpty {
                Button { lookUpZone(for: place, into: binding) } label: {
                    HStack(spacing: 4) {
                        if lookingUpZone { ProgressView().scaleEffect(0.55) }
                        Text("Find").font(.ui(12, weight: .semibold))
                    }
                    .foregroundStyle(Color.travelInk)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.travelInk.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(lookingUpZone)
            }
            if !binding.wrappedValue.isEmpty {
                Button { binding.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.ui(14)).foregroundStyle(Color.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
    }

    /// Geocode the place, then ask which zone that pin sits in — so no table of
    /// airports is needed and it works anywhere.
    private func lookUpZone(for place: String, into binding: Binding<String>) {
        zoneLookups += 1
        // "Home"/"Work"/"Gym" resolve to their saved addresses before
        // geocoding — the literal word "Home" geocodes to an arbitrary town.
        let target = resolvedPlace(place)
        Task {
            if let p = await GoogleMapsService.geocodePlace(target),
               let lat = p.lat, let lng = p.lng,
               let id = await GoogleMapsService.timeZoneID(lat: lat, lng: lng) {
                binding.wrappedValue = id
                rerenderClocks()
            }
            zoneLookups -= 1
        }
    }

    private func resolvedPlace(_ raw: String) -> String {
        let saved = (try? modelContext.fetch(FetchDescriptor<SavedLocation>())) ?? []
        if let match = saved.first(where: { $0.kind.rawValue.lowercased() == raw.lowercased() }),
           !match.address.isEmpty { return match.address }
        return raw
    }

    /// A zone that arrives after the sheet rendered must not reinterpret the
    /// digits on screen. Untouched pickers re-render the STORED instant on the
    /// new clock — same moment, new digits — so an open-and-save changes
    /// nothing. Pickers the user already moved keep their digits: what they
    /// typed is read in the zone now shown beneath the picker.
    private func rerenderClocks() {
        let stored = isFlight ? (segment.departAt == .distantPast ? nil : segment.departAt)
                              : segment.arriveBy
        if when == loadedWhen, let stored {
            when = TravelClock.wallClock(of: stored, in: zone(deadlineZoneID))
            loadedWhen = when
        }
        if arrives == loadedArrives, let a = segment.arriveAt {
            arrives = TravelClock.wallClock(of: a, in: zone(toZoneID))
            loadedArrives = arrives
        }
    }

    private func stepper(_ title: String, _ value: Binding<Int>, step: Int, unit: String) -> some View {
        HStack {
            Text(title).font(.ui(13.5)).foregroundStyle(Color.textSoft)
            Spacer()
            HStack(spacing: 10) {
                // The circle stays 28 pt — it is the visual design — but the
                // tappable area is 44. contentShape on the larger frame is
                // what separates "looks small" from "is hard to hit".
                Button { value.wrappedValue = max(0, value.wrappedValue - step) } label: {
                    Image(systemName: "minus").font(.ui(11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.bg))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.travelInk)
                .accessibilityLabel("Decrease \(title)")
                Text("\(value.wrappedValue) \(unit)")
                    .font(.ui(14, weight: .semibold)).monospacedDigit()
                    .frame(minWidth: 62)
                    .accessibilityLabel("\(title): \(value.wrappedValue) \(unit)")
                Button { value.wrappedValue += step } label: {
                    Image(systemName: "plus").font(.ui(11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.bg))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.travelInk)
                .accessibilityLabel("Increase \(title)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
    }
}

// MARK: - Notifications

enum TravelNotifier {
    /// A single nudge 30 minutes before you need to walk out of the door. This
    /// is the part that actually prevents a missed flight — the number sitting
    /// in a screen you don't open is worth nothing.
    static func schedule(segment: TravelSegment) async {
        let id = "travel-\(segment.id.uuidString)"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let plan = LeaveBy.plan(for: segment) else { return }
        // A chain with no journey time is missing its biggest leg — a nudge
        // computed from it would fire confidently wrong. The pending request
        // is already removed above, so a stale nudge dies here too.
        guard segment.travelMinutes > 0 else { return }
        let fire = plan.leaveAt.addingTimeInterval(-30 * 60)
        guard fire > Date() else { return }
        // Same authorization path as plan reminders — without it the nudge was
        // silently added-but-undeliverable for anyone who never granted
        // notifications, while chat promised "I'll nudge you 30 minutes before."
        guard await NotificationService.ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Leave in 30 minutes"
        // The leave time reads on the journey's own clock — the one the card
        // shows — with a zone label whenever that differs from the phone's.
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        f.timeZone = segment.fromTimeZone
        let zoneNote = segment.fromTimeZone.secondsFromGMT(for: plan.leaveAt)
            == TimeZone.current.secondsFromGMT(for: plan.leaveAt)
            ? "" : " \(TravelClock.label(segment.fromTimeZone, at: plan.leaveAt))"
        let what = segment.label.isEmpty ? segment.mode.label : segment.label
        content.body = "\(what) — leave at \(f.string(from: plan.leaveAt))\(zoneNote)"
            + (segment.toPlace.isEmpty ? "" : " for \(segment.toPlace)")
            + (plan.travelIsEstimated ? ". Journey time is an estimate." : ".")
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// A deleted journey takes its pending nudge with it.
    static func cancel(segment: TravelSegment) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["travel-\(segment.id.uuidString)"])
    }

    /// Removes pending leave-by nudges whose segment no longer exists —
    /// deletes on pre-fix builds didn't cancel, so a journey removed weeks ago
    /// could still ring at dawn. Runs at launch.
    static func purgeOrphans(context: ModelContext) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let travelIDs = pending.map(\.identifier).filter { $0.hasPrefix("travel-") }
        guard !travelIDs.isEmpty else { return }
        // Fail CLOSED: a failed fetch must read as "unknown", not "no
        // segments" — the ?? [] default would have cancelled every real
        // leave-by nudge on one transient store error.
        guard let segments = try? context.fetch(FetchDescriptor<TravelSegment>()) else { return }
        let live = Set(segments.map { "travel-\($0.id.uuidString)" })
        let orphans = travelIDs.filter { !live.contains($0) }
        if !orphans.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: orphans)
        }
    }
}

// MARK: - Travel palette

extension Color {
    /// A cooler ink than the warm editorial accent, so Travel mode is legible
    /// as a different mode at a glance.
    static let travelInk = Color(red: 0.18, green: 0.36, blue: 0.39)
    static let travelBg  = Color(red: 0.86, green: 0.91, blue: 0.92)
}
