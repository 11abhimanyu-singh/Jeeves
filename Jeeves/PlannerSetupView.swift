//
//  PlannerSetupView.swift
//  Jeeves
//
//  Where the day's anchors and the standing setup live: today's gym, today's
//  events (manual + ticket-screenshot ingestion, PRD §5.5), and the saved
//  Home/Work/Gym locations with addresses + facilities (PRD §5.4). Jeeves
//  reads all of this when it plans. Functional UI on the existing tokens,
//  not the dark-warm redesign.
//

import SwiftUI
import SwiftData
import PhotosUI

struct PlannerSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var dailyPlans: [DailyPlanState]
    @Query private var events: [DailyEvent]
    @State private var editingEvent: DailyEvent?
    @State private var showManualEvent = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isReadingTicket = false
    @State private var ticketError: String?
    @State private var detectedDraft: EventDraft?
    @State private var isImportingCalendar = false
    @State private var calendarReview: CalendarReview?

    private var today: Date { Date().startOfDay }
    private var todayEvents: [DailyEvent] { events.filter { $0.date == today }.sorted { $0.startMinute < $1.startMinute } }

    var body: some View {
        Form {
            gymSection.listRowBackground(Color.surface)
            eventsSection.listRowBackground(Color.surface)
        }
        .jeevesFormChrome()
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .sheet(isPresented: $showManualEvent) {
            EventEditSheet(draft: EventDraft(), onSave: saveEvent)
        }
        .sheet(item: $editingEvent) { event in
            EventEditSheet(draft: EventDraft(event: event), onSave: { draft in apply(draft, to: event) }, onDelete: {
                // Same rule as every other delete path: a synced event stays
                // deleted — tombstone its calendar ID or sync resurrects it.
                if !event.externalID.isEmpty {
                    modelContext.insert(CalendarTombstone(externalID: event.externalID))
                }
                modelContext.delete(event); modelContext.saveOrLog()
            })
        }
        .sheet(item: $detectedDraft) { draft in
            EventEditSheet(draft: draft, onSave: saveEvent)
        }
        .sheet(item: $calendarReview) { review in
            CalendarImportSheet(review: review, onAdd: addFromCalendar)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await readTicket(item); photoItem = nil }
        }
    }

    // MARK: Gym

    private var gymSection: some View {
        Section("Today's gym") {
            Toggle("Gym today", isOn: gymToggle)
            if gymToggle.wrappedValue {
                DatePicker("Gym starts", selection: gymTime, displayedComponents: .hourAndMinute)
            }
        }
    }

    private var gymToggle: Binding<Bool> {
        Binding(
            get: { todayPlanState()?.hasGymToday ?? false },
            set: { on in
                let state = todayPlanState(createIfNeeded: true)!
                state.hasGymToday = on
                if on && state.gymMinute == nil { state.gymMinute = 11 * 60 }
                modelContext.saveOrLog()
            }
        )
    }

    private var gymTime: Binding<Date> {
        Binding(
            get: {
                let minute = todayPlanState()?.gymMinute ?? 11 * 60
                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                let state = todayPlanState(createIfNeeded: true)!
                state.gymMinute = (comps.hour ?? 11) * 60 + (comps.minute ?? 0)
                modelContext.saveOrLog()
            }
        )
    }

    private func todayPlanState(createIfNeeded: Bool = false) -> DailyPlanState? {
        if let existing = dailyPlans.first(where: { $0.date == today }) { return existing }
        guard createIfNeeded else { return nil }
        return DailyPlanState.fetchOrCreate(for: today, in: modelContext)
    }

    // MARK: Events

    private var eventsSection: some View {
        Section {
            ForEach(todayEvents) { event in
                Button { editingEvent = event } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.ui(15, weight: .semibold)).foregroundStyle(Color.textPrimary)
                        Text("\(hhmm(event.startMinute))–\(hhmm(event.endMinute)) · from \(event.outboundStart.rawValue)")
                            .font(.ui(12)).foregroundStyle(Color.textSoft)
                        if !event.destinationAddress.isEmpty {
                            Text(event.destinationAddress).font(.ui(11.5)).foregroundStyle(Color.textMuted)
                        }
                    }
                }
            }

            Button { showManualEvent = true } label: {
                Label("Add event manually", systemImage: "plus")
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Add from ticket screenshot", systemImage: "photo.on.rectangle")
            }
            Button { importFromCalendar() } label: {
                Label("Import from my calendars", systemImage: "calendar")
            }
            if isReadingTicket {
                HStack { ProgressView(); Text("Reading ticket…").font(.ui(12.5)).foregroundStyle(Color.textMuted) }
            }
            if isImportingCalendar {
                HStack { ProgressView(); Text("Importing from calendar…").font(.ui(12.5)).foregroundStyle(Color.textMuted) }
            }
            if let ticketError {
                Text(ticketError).font(.ui(12)).foregroundStyle(Color.accentDeep)
            }
        } header: {
            Text("Today's events")
        } footer: {
            Text("Events are hard anchors — Jeeves fits all planned work before you leave for the earliest one.")
        }
    }

    private func readTicket(_ item: PhotosPickerItem) async {
        isReadingTicket = true
        ticketError = nil
        defer { isReadingTicket = false }
        guard let data = try? await item.loadTransferable(type: Data.self), let uiImage = UIImage(data: data) else {
            ticketError = "Couldn't load that image."
            return
        }
        do {
            let detected = try await EventVisionService.detectEvent(in: uiImage)
            detectedDraft = EventDraft(detected: detected)
        } catch {
            ticketError = error.localizedDescription
        }
    }

    /// Fetches the day's calendar and hands it to the SAME review sheet the
    /// planner uses. This used to insert every event silently — which put two
    /// import paths in the app with different contracts, and broke the promise
    /// (PRD §5.3) that calendar events are reviewed before they land.
    private func importFromCalendar() {
        isImportingCalendar = true
        ticketError = nil
        Task {
            defer { isImportingCalendar = false }
            guard await EventKitService.requestAccess() else {
                ticketError = "Jeeves doesn't have calendar access. Turn it on in iOS Settings → Privacy & Security → Calendars → Jeeves."
                return
            }
            let end = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
            let calEvents = EventKitService.events(from: today, to: end,
                                                   calendarIDs: EventKitService.selectedCalendarIDs)
            // Deleted synced events stay deleted — this path used to
            // resurrect tombstoned events (and imported them without
            // their externalID, so later syncs duplicated them).
            let dead = CalendarTombstone.ids(in: modelContext)
            let offerable = calEvents.filter { c in
                guard c.externalID.isEmpty || !dead.contains(c.externalID) else { return false }
                // Already on the day — nothing to offer.
                return !todayEvents.contains { $0.title == c.title && $0.startMinute == c.startMinute }
            }
            if offerable.isEmpty {
                ticketError = "Nothing new in your calendars for today."
            } else {
                calendarReview = CalendarReview(date: today, events: offerable)
            }
        }
    }

    /// Adds only what the user ticked in the review sheet.
    private func addFromCalendar(_ chosen: [CalendarEvent]) {
        for c in chosen {
            modelContext.insert(DailyEvent(
                date: today, title: c.title,
                startMinute: c.startMinute, endMinute: c.endMinute,
                destinationAddress: c.location, outboundStart: .home, source: .calendar,
                isAllDay: c.isAllDay,
                externalID: c.externalID
            ))
        }
        modelContext.saveOrLog()
    }

    private func saveEvent(_ draft: EventDraft) {
        let event = DailyEvent(
            date: draft.date.startOfDay, title: draft.title,
            startMinute: draft.startMinute, endMinute: draft.endMinute,
            destinationAddress: draft.address, outboundStart: draft.outboundStart,
            source: draft.source
        )
        modelContext.insert(event)
        modelContext.saveOrLog()
        resolveDestinationIfLink(for: event)
    }

    private func apply(_ draft: EventDraft, to event: DailyEvent) {
        event.title = draft.title
        event.date = draft.date.startOfDay
        event.startMinute = draft.startMinute
        event.endMinute = draft.endMinute
        event.destinationAddress = draft.address
        event.outboundStart = draft.outboundStart
        modelContext.saveOrLog()
        resolveDestinationIfLink(for: event)
    }

    /// If the venue was pasted as a Google Maps link, identify the place in the
    /// background and replace the opaque URL with its name (e.g. "BlueStone
    /// Jewellery Koramangala"). Falls back to the raw link if it can't resolve,
    /// so there's no regression, and routing then geocodes the clean name.
    private func resolveDestinationIfLink(for event: DailyEvent) {
        let raw = event.destinationAddress
        guard !raw.isEmpty, event.destinationLat == nil else { return }
        Task {
            // Links resolve to their pin; typed/spoken venues are geocoded as
            // free text, so every venue ends up with real coordinates.
            let place = GoogleMapsService.isMapsLink(raw)
                ? await GoogleMapsService.resolvePlace(raw)
                : await GoogleMapsService.geocodePlace(raw)
            guard let place, place.lat != nil else { return }
            event.destinationAddress = place.displayAddress
            event.destinationLat = place.lat
            event.destinationLng = place.lng
            modelContext.saveOrLog()
        }
    }

    private func hhmm(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

// MARK: - Event draft + edit sheet

struct EventDraft: Identifiable {
    let id = UUID()
    var title = ""
    var date: Date = Date().startOfDay
    var startMinute = 14 * 60
    var endMinute = 17 * 60
    var address = ""
    var outboundStart: LocationKind = .home
    var source: EventSource = .manual
    /// The event being edited, carried INSIDE the sheet's item. Deriving
    /// "can delete" from a separate @State raced the sheet's snapshot — the
    /// delete button sometimes built against a stale nil and vanished.
    var existingEvent: DailyEvent? = nil

    init() {}

    /// New event pre-dated to a chosen day (e.g. the day selected on the planner dial).
    init(on day: Date) { date = day.startOfDay }

    init(event: DailyEvent) {
        title = event.title
        date = event.date
        startMinute = event.startMinute
        endMinute = event.endMinute
        address = event.destinationAddress
        outboundStart = event.outboundStart
        source = event.source
        existingEvent = event
    }

    init(detected: DetectedEvent) {
        title = detected.title
        // A ticket carries its own date — honor it so a future-dated ticket
        // lands on the right day instead of always today.
        if let ds = detected.date, let parsed = EventDraft.parseDate(ds) { date = parsed }
        if let s = detected.startTime, let m = GeneratedBlock.minutes(from: s) { startMinute = m }
        if let e = detected.endTime, let m = GeneratedBlock.minutes(from: e) { endMinute = m }
        else { endMinute = startMinute + 180 }  // sensible default span
        address = detected.venue ?? ""
        source = .screenshot
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: s)?.startOfDay
    }
}

struct EventEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: EventDraft
    let onSave: (EventDraft) -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Title", text: $draft.title)
                    TextField("Venue / address", text: $draft.address)
                }
                .listRowBackground(Color.surface)
                Section("Date") {
                    DatePicker("Day", selection: $draft.date, displayedComponents: .date)
                }
                .listRowBackground(Color.surface)
                Section("Time") {
                    DatePicker("Starts", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                }
                .listRowBackground(Color.surface)
                Section("Leaving from") {
                    Picker("Leaving from", selection: $draft.outboundStart) {
                        ForEach(LocationKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.surface)
                if let onDelete {
                    Section {
                        Button("Delete event", role: .destructive) { onDelete(); dismiss() }
                    }
                    .listRowBackground(Color.surface)
                }
            }
            .jeevesFormChrome()
            .navigationTitle(draft.source == .screenshot ? "Confirm event" : "Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }
                        .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<EventDraft, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = draft[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }
}
