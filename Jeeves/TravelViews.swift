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
                    .font(.system(size: 13, weight: .semibold))
                Text("TRAVEL MODE")
                    .font(.system(size: 11, weight: .bold)).kerning(1.2)
                Spacer()
                Button { showTrip = true } label: {
                    Text(trip.title.isEmpty ? "Trip" : trip.title)
                        .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 12.5))
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

    private var plan: LeaveBy.Plan? { LeaveBy.plan(for: segment) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: segment.mode.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.travelInk)
                Text(segment.label.isEmpty ? segment.mode.label : segment.label)
                    .font(Font.serif(16, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if !segment.toPlace.isEmpty {
                    Text(segment.toPlace)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
            }

            if let plan {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("Leave")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textSoft)
                    Text(hhmm(plan.leaveAt))
                        .font(Font.serif(34, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.travelInk)
                    if crossesZones {
                        Text(TravelClock.label(segment.fromTimeZone, at: plan.leaveAt))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.textMuted)
                    }
                }

                // An arrival in another zone is meaningless without saying which
                // clock it's on — and whether it lands on the next day.
                if let arriveAt = segment.arriveAt {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.right").font(.system(size: 10))
                        Text("Arrives \(TravelClock.hhmm(arriveAt, in: segment.toTimeZone)) "
                             + TravelClock.label(segment.toTimeZone, at: arriveAt))
                            .font(.system(size: 12, weight: .medium))
                        if TravelClock.crossesDay(departure: segment.departAt,
                                                  departureZone: segment.fromTimeZone,
                                                  arrival: arriveAt, arrivalZone: segment.toTimeZone) {
                            Text("next day")
                                .font(.system(size: 9.5, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accent.opacity(0.18)))
                                .foregroundStyle(Color.accentDeep)
                        }
                        if let off = TravelClock.offsetLabel(from: segment.fromTimeZone,
                                                             to: segment.toTimeZone, at: arriveAt) {
                            Text("clock \(off)")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.textMuted)
                        }
                    }
                    .foregroundStyle(Color.textSoft)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .fill(step.isLeave ? Color.travelInk : Color.textMuted.opacity(0.4))
                                .frame(width: step.isLeave ? 8 : 6, height: step.isLeave ? 8 : 6)
                                .padding(.top, 6)
                            Text(hhmm(step.time))
                                .font(.system(size: 13, weight: step.isLeave ? .bold : .regular))
                                .monospacedDigit()
                                .foregroundStyle(step.isLeave ? Color.travelInk : Color.textPrimary)
                                .frame(width: 46, alignment: .leading)
                            Text(step.label)
                                .font(.system(size: 12.5, weight: step.isLeave ? .semibold : .regular))
                                .foregroundStyle(step.isLeave ? Color.travelInk : Color.textSoft)
                            Spacer(minLength: 4)
                            Text(step.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.textMuted)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 3)
                    }
                }

                Text(plan.travelIsEstimated
                     ? "Journey time is an estimate — tap Measure to price it against live traffic. Cut-off, security and buffer are always your assumptions."
                     : "Journey measured against live traffic. Cut-off, security and buffer are your assumptions.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.textMuted)
                    .padding(.top, 2)

                if !segment.toPlace.isEmpty {
                    Button { measure() } label: {
                        HStack(spacing: 6) {
                            if pricing { ProgressView().scaleEffect(0.6) }
                            Image(systemName: "location.fill").font(.system(size: 10))
                            Text(pricing ? "Measuring…" : "Measure the journey")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.travelInk)
                        .padding(.vertical, 8).frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.travelInk.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .disabled(pricing)
                }
            } else {
                Text(segment.mode == .drive
                     ? "Add the time you must arrive and I'll work backwards."
                     : "Add the departure time and I'll work backwards.")
                    .font(.system(size: 12.5))
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
        let from = segment.fromPlace
        let to = segment.toPlace
        let target = LeaveBy.plan(for: segment)?.leaveAt ?? Date()
        Task {
            let origin = await resolvedOrigin(from)
            if let minutes = await GoogleMapsService.commuteMinutes(from: origin, to: to,
                                                                   departure: max(target, Date())) {
                segment.travelMinutes = minutes
                segment.travelIsEstimated = false
                modelContext.saveOrLog("LeaveByCard.measure")
                await TravelNotifier.schedule(segment: segment)
            }
            pricing = false
        }
    }

    /// "Home"/"Work"/"Gym" resolve to their saved addresses; anything else is
    /// already a place.
    private func resolvedOrigin(_ raw: String) async -> String {
        let saved = (try? modelContext.fetch(FetchDescriptor<SavedLocation>())) ?? []
        if raw.isEmpty {
            return saved.first { $0.kind == .home }?.address ?? "Home"
        }
        if let match = saved.first(where: { $0.kind.rawValue.lowercased() == raw.lowercased() }) {
            return match.address.isEmpty ? raw : match.address
        }
        return raw
    }

    /// Every step of the chain happens where the journey STARTS, so the whole
    /// countdown is read on that clock — the one you're actually looking at.
    private func hhmm(_ d: Date) -> String {
        TravelClock.hhmm(d, in: segment.fromTimeZone)
    }

    private var crossesZones: Bool {
        segment.fromTimeZone.secondsFromGMT(for: segment.departAt)
            != segment.toTimeZone.secondsFromGMT(for: segment.departAt)
            || !segment.fromTimeZoneID.isEmpty
    }
}

// MARK: - Trip editor

struct TripEditorView: View {
    let trip: Trip
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allSegments: [TravelSegment]

    @State private var editing: TravelSegment?

    private var segments: [TravelSegment] {
        allSegments.filter { $0.tripID == trip.id }
            .sorted { ($0.arriveBy ?? $0.departAt) < ($1.arriveBy ?? $1.departAt) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        stat("Days", "\(trip.dayCount)")
                        stat("Journeys", "\(segments.count)")
                    }
                    Text("The planner stands down for every day of this trip. What you get instead are the journeys below.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textMuted)
                        .padding(.bottom, 2)

                    ForEach(segments, id: \.id) { s in
                        Button { editing = s } label: { LeaveByCard(segment: s) }
                            .buttonStyle(.plain)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(Color.accentDeep)
                }
            }
            .sheet(item: $editing) { SegmentEditorView(segment: $0) }
        }
    }

    private func newSegment(_ mode: TravelMode) -> TravelSegment {
        let noon = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: trip.startDate) ?? trip.startDate
        let s = TravelSegment(tripID: trip.id, mode: mode,
                              label: mode == .flight ? "" : "Drive",
                              departAt: mode == .flight ? noon : .distantPast,
                              arriveBy: mode == .drive ? noon : nil,
                              checkInMinutes: mode == .flight ? 180 : 0,
                              securityMinutes: mode == .flight ? 30 : 0)
        modelContext.insert(s)
        modelContext.saveOrLog("TripEditor.newSegment")
        return s
    }

    private func addLabel(_ t: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13))
            Text(t).font(.system(size: 14.5, weight: .semibold))
        }
        .foregroundStyle(Color.travelInk)
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .overlay(RoundedRectangle(cornerRadius: 13)
            .strokeBorder(Color.travelInk.opacity(0.4), style: StrokeStyle(lineWidth: 1.3, dash: [5])))
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.8)
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
    @State private var arrives = Date()
    @State private var fromZoneID = ""
    @State private var toZoneID = ""
    @State private var lookingUpZone = false
    @State private var measuring = false
    @State private var measureFailed = false
    @State private var travelMeasured = false

    private var isFlight: Bool { segment.mode != .drive }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    field("Name", text: $label, placeholder: isFlight ? "6E 1605" : "Drive to Bhadra")
                    field("From", text: $from, placeholder: "Home — or a hotel address")
                    field("To", text: $to, placeholder: isFlight ? "BLR airport" : "JLR River Tern Lodge")

                    DatePicker(isFlight ? "Departs" : "Must arrive by",
                               selection: $when, displayedComponents: [.date, .hourAndMinute])
                        .font(.system(size: 14))
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))

                    // The clock the time above is read on. Getting this wrong is
                    // the difference between making a flight and missing it, so
                    // it's stated rather than assumed.
                    zoneRow("Time is local to", $fromZoneID, place: from.isEmpty ? "Home" : from)
                    if isFlight {
                        DatePicker("Arrives", selection: $arrives,
                                   displayedComponents: [.date, .hourAndMinute])
                            .font(.system(size: 14))
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
                        zoneRow("Arrival clock", $toZoneID, place: to)
                        if let off = TravelClock.offsetLabel(from: zone(fromZoneID), to: zone(toZoneID),
                                                             at: Date()) {
                            Text("Destination clock is \(off) from where you leave.")
                                .font(.system(size: 11)).foregroundStyle(Color.textMuted)
                        }
                    }

                    Text("ASSUMPTIONS — CORRECT THEM ONCE")
                        .font(.system(size: 10, weight: .bold)).kerning(1)
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
                }
                .padding(18)
            }
            .background(Color.bg)
            .navigationTitle(isFlight ? "Flight" : "Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        modelContext.delete(segment)
                        modelContext.saveOrLog("SegmentEditor.delete")
                        dismiss()
                    } label: { Image(systemName: "trash") }.tint(.red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }.tint(Color.accentDeep)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        label = segment.label; from = segment.fromPlace; to = segment.toPlace
        fromZoneID = segment.fromTimeZoneID; toZoneID = segment.toTimeZoneID
        // Show stored instants as the wall-clock they read on their own zone,
        // so opening and saving without edits changes nothing.
        let stored = isFlight ? (segment.departAt == .distantPast ? nil : segment.departAt)
                              : segment.arriveBy
        when = stored.map { TravelClock.wallClock(of: $0, in: zone(fromZoneID)) } ?? Date()
        arrives = segment.arriveAt.map { TravelClock.wallClock(of: $0, in: zone(toZoneID)) } ?? when
        checkIn = segment.checkInMinutes; security = segment.securityMinutes
        buffer = segment.bufferMinutes; stops = segment.stopMinutes; travel = segment.travelMinutes
        travelMeasured = !segment.travelIsEstimated
        // Nothing measured yet but we know where we're going — do it now rather
        // than making the user type a distance.
        if travel == 0, !to.isEmpty { measureJourney() }
    }

    private func save() {
        segment.label = label
        segment.fromPlace = from
        segment.toPlace = to
        segment.fromTimeZoneID = fromZoneID
        segment.toTimeZoneID = toZoneID
        // Read the typed wall-clock on the journey's own clock, not the phone's.
        let departInstant = TravelClock.instant(readingWallClock: when, in: zone(fromZoneID))
        if isFlight {
            segment.departAt = departInstant
            segment.arriveBy = nil
            segment.arriveAt = TravelClock.instant(readingWallClock: arrives, in: zone(toZoneID))
        } else {
            segment.arriveBy = departInstant
            segment.arriveAt = nil
        }
        segment.checkInMinutes = checkIn
        segment.securityMinutes = security
        segment.bufferMinutes = buffer
        segment.stopMinutes = stops
        segment.travelMinutes = travel
        segment.travelIsEstimated = !travelMeasured
        modelContext.saveOrLog("SegmentEditor.save")
        Task { await TravelNotifier.schedule(segment: segment) }
        dismiss()
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.8)
                .foregroundStyle(Color.textMuted)
            TextField(placeholder, text: text)
                .font(.system(size: 15))
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.surface))
        }
    }

    /// How long the journey takes is Google's job, not the user's. This row
    /// measures it on its own; the manual stepper only appears when the lookup
    /// fails, and says why.
    @ViewBuilder
    private var journeyRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("JOURNEY TIME").font(.system(size: 9.5, weight: .bold)).kerning(0.7)
                        .foregroundStyle(Color.textMuted)
                    if measuring {
                        Text("Measuring against live traffic\u{2026}")
                            .font(.system(size: 13)).foregroundStyle(Color.textSoft)
                    } else if travel > 0 {
                        Text(LeaveBy.hours(travel)
                             + (travelMeasured ? " \u{00B7} live traffic" : " \u{00B7} entered by you"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                    } else if measureFailed {
                        Text("Couldn't find that place")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.accentDeep)
                    } else {
                        Text("Add a destination and I'll measure it")
                            .font(.system(size: 13)).foregroundStyle(Color.textMuted)
                    }
                }
                Spacer(minLength: 6)
                if measuring { ProgressView().scaleEffect(0.6) }
                else if !to.isEmpty {
                    Button { measureJourney() } label: {
                        Text(travel > 0 ? "Re-measure" : "Measure")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.travelInk)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Capsule().fill(Color.travelInk.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))

            // Only ask once the automatic route has actually failed.
            if measureFailed || (travel > 0 && !travelMeasured) {
                stepper("Override", $travel, step: 15, unit: "min")
                Text(measureFailed
                     ? "I couldn't route to \u{201C}\(to)\u{201D} — give me a rough number and I'll work backwards from it."
                     : "Using your number. Tap Measure to price the real route instead.")
                    .font(.system(size: 11)).foregroundStyle(Color.textMuted)
            }
        }
    }

    /// Price the route now, from wherever this leg starts.
    private func measureJourney() {
        guard !to.isEmpty else { return }
        measuring = true
        measureFailed = false
        let originRaw = from.isEmpty ? "Home" : from
        Task {
            let saved = (try? modelContext.fetch(FetchDescriptor<SavedLocation>())) ?? []
            let origin = saved.first { $0.kind.rawValue.lowercased() == originRaw.lowercased() }
                .map(\.address).flatMap { $0.isEmpty ? nil : $0 } ?? originRaw
            if let m = await GoogleMapsService.commuteMinutes(from: origin, to: to,
                                                             departure: max(when, Date())) {
                travel = m
                travelMeasured = true
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
                Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).kerning(0.7)
                    .foregroundStyle(Color.textMuted)
                Text(binding.wrappedValue.isEmpty
                     ? "This phone (\(TravelClock.label(.current)))"
                     : "\(binding.wrappedValue) (\(TravelClock.label(zone(binding.wrappedValue))))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if !place.isEmpty {
                Button { lookUpZone(for: place, into: binding) } label: {
                    HStack(spacing: 4) {
                        if lookingUpZone { ProgressView().scaleEffect(0.55) }
                        Text("Find").font(.system(size: 12, weight: .semibold))
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
                        .font(.system(size: 14)).foregroundStyle(Color.textMuted)
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
        lookingUpZone = true
        Task {
            if let p = await GoogleMapsService.geocodePlace(place),
               let lat = p.lat, let lng = p.lng,
               let id = await GoogleMapsService.timeZoneID(lat: lat, lng: lng) {
                binding.wrappedValue = id
            }
            lookingUpZone = false
        }
    }

    private func stepper(_ title: String, _ value: Binding<Int>, step: Int, unit: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13.5)).foregroundStyle(Color.textSoft)
            Spacer()
            HStack(spacing: 10) {
                Button { value.wrappedValue = max(0, value.wrappedValue - step) } label: {
                    Image(systemName: "minus").font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.bg))
                }.buttonStyle(.plain).foregroundStyle(Color.travelInk)
                Text("\(value.wrappedValue) \(unit)")
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .frame(minWidth: 62)
                Button { value.wrappedValue += step } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.bg))
                }.buttonStyle(.plain).foregroundStyle(Color.travelInk)
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
        let fire = plan.leaveAt.addingTimeInterval(-30 * 60)
        guard fire > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Leave in 30 minutes"
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let what = segment.label.isEmpty ? segment.mode.label : segment.label
        content.body = "\(what) — leave at \(f.string(from: plan.leaveAt))"
            + (segment.toPlace.isEmpty ? "" : " for \(segment.toPlace)")
            + (plan.travelIsEstimated ? ". Journey time is an estimate." : ".")
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

// MARK: - Travel palette

extension Color {
    /// A cooler ink than the warm editorial accent, so Travel mode is legible
    /// as a different mode at a glance.
    static let travelInk = Color(red: 0.18, green: 0.36, blue: 0.39)
    static let travelBg  = Color(red: 0.86, green: 0.91, blue: 0.92)
}
