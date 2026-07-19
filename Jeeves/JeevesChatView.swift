//
//  JeevesChatView.swift
//  Jeeves
//
//  The Jeeves planner interface: free-text chat plus a "Plan my day" action
//  that gathers today's real context (gym, events, saved locations, prep
//  neglect, live commute times) and asks Claude to produce a structured,
//  human-reasoned plan (PRD §5, §6). Renders the plan inline as a timeline,
//  with the deterministic DayPlanner as the offline fallback.
//
//  Built on the app's existing warm-editorial-light tokens, not the PRD's
//  dark-warm/NYT redesign (§3) — that reskin is a separate, later phase.
//

import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct JeevesChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var dailyPlans: [DailyPlanState]
    @Query private var events: [DailyEvent]
    @Query private var locations: [SavedLocation]
    @Query private var prepSessions: [PrepSession]

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isSending = false
    @State private var isPlanning = false
    @State private var errorText: String?
    @State private var showSetup = false
    @State private var showSettings = false

    // In-chat ticket upload → event ingestion.
    @State private var photoItem: PhotosPickerItem?
    @State private var isReadingTicket = false
    @State private var detectedDraft: EventDraft?

    private var today: Date { Date().startOfDay }
    private var todayPlanState: DailyPlanState? { dailyPlans.first { $0.date == today } }
    private var todayEvents: [DailyEvent] { events.filter { $0.date == today }.sorted { $0.startMinute < $1.startMinute } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.textPrimary.opacity(0.14))
            planMyDayBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            Text("Tell Jeeves about your day, or tap Plan my day. Jeeves reasons like a human planner — chaining trips, using the gym shower, moving lunch near your event — not just packing blocks into gaps.")
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color.textMuted)
                                .multilineTextAlignment(.center)
                                .padding(.top, 24).padding(.horizontal, 24)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        ForEach(messages) { message in
                            messageView(message).id(message.id)
                        }

                        if isSending || isPlanning || isReadingTicket {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(planningStatus)
                                    .font(.system(size: 12.5)).foregroundStyle(Color.textMuted)
                            }
                            .padding(.leading, 4)
                        }

                        if let errorText {
                            Text(errorText).font(.system(size: 12.5)).foregroundStyle(Color.accentDeep)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    guard let last = messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider().overlay(Color.textPrimary.opacity(0.1))
            inputBar
        }
        .background(Color.bg)
        .sheet(isPresented: $showSetup) {
            NavigationStack { PlannerSetupView() }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(item: $detectedDraft) { draft in
            EventEditSheet(draft: draft, onSave: addEventFromChat)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await readTicket(item); photoItem = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accent)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "sparkles").foregroundStyle(.white).font(.system(size: 13)))
            Text("Jeeves").font(.heading(18)).foregroundStyle(Color.textPrimary)
            Spacer()
            // Calendar = today's anchors (gym + events, changes daily).
            Button { showSetup = true } label: {
                Image(systemName: "calendar").font(.system(size: 16)).foregroundStyle(Color.textSoft)
            }
            // Gear = standing configuration (keys, integrations, locations).
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 16)).foregroundStyle(Color.textSoft)
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
    }

    private var planMyDayBar: some View {
        HStack(spacing: 10) {
            Button(action: planMyDay) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold))
                    Text("Plan my day").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accent))
            }
            .buttonStyle(.plain)
            .disabled(isPlanning || isSending)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Message rendering

    @ViewBuilder
    private func messageView(_ message: ChatMessage) -> some View {
        if let plan = message.plan {
            PlanTimelineCard(plan: plan, isOffline: message.isOfflinePlan)
        } else {
            bubble(for: message)
        }
    }

    private func bubble(for message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.content)
                .font(.system(size: 14.5))
                .foregroundStyle(message.role == .user ? .white : Color.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16).fill(message.role == .user ? Color.accent : Color.surface))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Attach a ticket screenshot → Jeeves reads it and drafts an event.
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.textSoft)
                    .padding(.bottom, 4)
            }

            TextField("Message Jeeves…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .foregroundStyle(Color.textPrimary)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))

            Button(action: sendChat) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.accent : Color.textMuted.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.bg)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && !isPlanning
    }

    // MARK: Free-text chat

    private func sendChat() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let priorHistory = messages.filter { $0.plan == nil }
        messages.append(ChatMessage(role: .user, content: text))
        inputText = ""
        errorText = nil
        isSending = true

        Task {
            do {
                let reply = try await JeevesChatService.send(history: priorHistory, newMessage: text)
                messages.append(ChatMessage(role: .assistant, content: reply))
            } catch {
                errorText = error.localizedDescription
            }
            isSending = false
        }
    }

    // MARK: Plan generation

    private func planMyDay() {
        errorText = nil
        isPlanning = true
        let userContext = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userContext.isEmpty {
            messages.append(ChatMessage(role: .user, content: userContext))
            inputText = ""
        }

        Task {
            // 1. Pull any events/gym mentioned in the message into real anchors,
            //    so "MLR at 7pm, plan my day" works without manual event entry.
            let planEvents = await extractAndCreateAnchors(from: userContext)
            // 2. Build the request from those anchors (incl. live Maps commute).
            let req = await buildPlanRequest(userContext: userContext, events: planEvents)
            // 3. Generate.
            do {
                let plan = try await PlanGenerationService.generate(req)
                messages.append(ChatMessage(role: .assistant, content: plan.summary))
                messages.append(ChatMessage(role: .assistant, content: "", plan: plan))
            } catch {
                // Offline / error fallback: deterministic engine (PRD §6).
                let fallback = deterministicPlan()
                messages.append(ChatMessage(role: .assistant, content: "I couldn't reach the planning service, so here's an offline plan from the built-in scheduler. (\(error.localizedDescription))"))
                messages.append(ChatMessage(role: .assistant, content: "", plan: fallback, isOfflinePlan: true))
            }
            isPlanning = false
        }
    }

    /// Extracts events/gym from the message, persists any new ones, and returns
    /// the full set of today's events (existing + newly created) for planning.
    /// On extraction failure, quietly falls back to whatever's already set up.
    private func extractAndCreateAnchors(from message: String) async -> [DailyEvent] {
        guard !message.isEmpty else { return todayEvents }
        guard let anchors = try? await AnchorExtractionService.extract(from: message, existingTitles: todayEvents.map(\.title)) else {
            return todayEvents
        }

        var created: [DailyEvent] = []
        for e in anchors.events {
            let title = e.title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            // Skip anything that duplicates an existing event today.
            if todayEvents.contains(where: { $0.title.lowercased() == title.lowercased() }) { continue }
            let start = e.startTime.flatMap(GeneratedBlock.minutes(from:)) ?? 19 * 60
            let end = e.endTime.flatMap(GeneratedBlock.minutes(from:)) ?? (start + 180)
            let from = LocationKind(rawValue: e.leavingFrom ?? "Home") ?? .home
            let event = DailyEvent(
                date: today, title: title, startMinute: start, endMinute: end,
                destinationAddress: e.venue ?? "", outboundStart: from, source: .manual
            )
            modelContext.insert(event)
            created.append(event)
        }

        // Gym, only if the message actually mentioned it.
        if let gymToday = anchors.gymToday {
            let state = todayPlanState ?? {
                let s = DailyPlanState(date: today, hasGymToday: false, gymMinute: nil)
                modelContext.insert(s); return s
            }()
            state.hasGymToday = gymToday
            if let gt = anchors.gymTime.flatMap(GeneratedBlock.minutes(from:)) { state.gymMinute = gt }
        }

        try? modelContext.save()
        return todayEvents + created
    }

    private func buildPlanRequest(userContext: String, events planEvents: [DailyEvent]) async -> PlanRequest {
        let hasGym = todayPlanState?.hasGymToday ?? false
        let gymMinute = todayPlanState?.gymMinute

        // Live commute legs. Event venues (place names) work directly as Maps
        // origins/destinations, so an extracted "MLR Convention Centre" routes
        // even without a saved address for it.
        var legs: [(label: String, from: String, to: String)] = []
        let homeAddr = locations.first { $0.kind == .home }?.address ?? ""
        let gymAddr = locations.first { $0.kind == .gym }?.address ?? ""
        if hasGym, !homeAddr.isEmpty, !gymAddr.isEmpty {
            legs.append(("Home→Gym", homeAddr, gymAddr))
            legs.append(("Gym→Home", gymAddr, homeAddr))
        }
        for e in planEvents where !e.destinationAddress.isEmpty {
            let fromAddr = locations.first { $0.kind == e.outboundStart }?.address ?? homeAddr
            if !fromAddr.isEmpty {
                legs.append(("\(e.outboundStart.rawValue)→\(e.title)", fromAddr, e.destinationAddress))
            }
            if !homeAddr.isEmpty {
                legs.append(("\(e.title)→Home", e.destinationAddress, homeAddr))
            }
        }
        let commutes = await GoogleMapsService.commuteEstimates(legs: legs)

        return PlanRequest(
            userMessage: userContext,
            hasGymToday: hasGym,
            gymMinute: gymMinute,
            events: planEvents.sorted { $0.startMinute < $1.startMinute },
            locations: locations,
            defaultCommuteMinutes: 30,
            commuteEstimates: commutes,
            prepNeglectNote: prepNeglectNote()
        )
    }

    private var planningStatus: String {
        if isPlanning { return "Jeeves is planning your day…" }
        if isReadingTicket { return "Reading your ticket…" }
        return "Jeeves is thinking…"
    }

    // MARK: In-chat ticket upload

    private func readTicket(_ item: PhotosPickerItem) async {
        isReadingTicket = true
        errorText = nil
        defer { isReadingTicket = false }
        guard let data = try? await item.loadTransferable(type: Data.self), let uiImage = UIImage(data: data) else {
            errorText = "Couldn't load that image."
            return
        }
        do {
            let detected = try await EventVisionService.detectEvent(in: uiImage)
            detectedDraft = EventDraft(detected: detected)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func addEventFromChat(_ draft: EventDraft) {
        let event = DailyEvent(
            date: today, title: draft.title,
            startMinute: draft.startMinute, endMinute: draft.endMinute,
            destinationAddress: draft.address, outboundStart: draft.outboundStart, source: draft.source
        )
        modelContext.insert(event)
        try? modelContext.save()
        messages.append(ChatMessage(role: .assistant, content: "Added to today: \(draft.title) at \(hhmm(draft.startMinute)). Tap Plan my day and I'll fit everything around it."))
    }

    private func hhmm(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// Which practice categories are most neglected this week — mirrors the
    /// deterministic engine's weighting so Claude gets the same signal.
    private func prepNeglectNote() -> String? {
        let categories: [PrepCategory] = [.productSense, .execution, .strategy, .behavioral]
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let recent = prepSessions.filter { $0.date >= weekAgo && $0.category != .reading }
        let counts = Dictionary(grouping: recent, by: { $0.category }).mapValues(\.count)
        let ranked = categories.sorted { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
        return "Fewest practice sessions this week (most neglected first): " + ranked.map(\.rawValue).joined(separator: ", ")
    }

    /// Offline fallback — converts the deterministic DayPlanner's output into
    /// the same GeneratedPlan shape the timeline card renders.
    private func deterministicPlan() -> GeneratedPlan {
        let blocks = DayPlanner.generate(
            gymMinute: (todayPlanState?.hasGymToday ?? false) ? todayPlanState?.gymMinute : nil,
            prepSessions: prepSessions,
            leisureLogs: []
        )
        let generated = blocks.map { b in
            GeneratedBlock(
                title: b.title,
                startTime: String(format: "%02d:%02d", b.startMinute / 60, b.startMinute % 60),
                endTime: String(format: "%02d:%02d", b.endMinute / 60, b.endMinute % 60),
                note: b.note,
                isAnchor: b.isAnchor,
                kind: b.isAnchor ? "anchor" : "activity"
            )
        }
        return GeneratedPlan(blocks: generated, dropped: [], shrunk: [], summary: "", boundaryTime: nil)
    }
}

// MARK: - Plan timeline card

private struct PlanTimelineCard: View {
    let plan: GeneratedPlan
    let isOffline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isOffline ? "OFFLINE PLAN" : "TODAY'S PLAN")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.textMuted)
                Spacer()
                if let boundary = plan.boundaryTime {
                    Text("until \(boundary)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentDeep)
                }
            }
            .padding(.bottom, 10)

            ForEach(Array(plan.blocks.enumerated()), id: \.offset) { _, block in
                blockRow(block)
            }

            if !plan.dropped.isEmpty || !plan.shrunk.isEmpty {
                Divider().overlay(Color.textPrimary.opacity(0.1)).padding(.vertical, 8)
                if !plan.dropped.isEmpty {
                    changeLine(label: "Dropped to fit", items: plan.dropped)
                }
                if !plan.shrunk.isEmpty {
                    changeLine(label: "Shortened", items: plan.shrunk)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private func blockRow(_ block: GeneratedBlock) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(block.startTime)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(block.isAnchor ? Color.accentDeep : Color.textSoft)
                .frame(width: 46, alignment: .leading)
            Rectangle()
                .fill(block.isAnchor ? Color.accent : Color.sage.opacity(0.5))
                .frame(width: 3).cornerRadius(1.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.title)
                    .font(.system(size: 14, weight: block.isAnchor ? .bold : .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = block.note, !note.isEmpty {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    private func changeLine(label: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.textMuted)
            Text(items.joined(separator: ", ")).font(.system(size: 12.5)).foregroundStyle(Color.textSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    JeevesChatView()
        .modelContainer(for: [DailyPlanState.self, DailyEvent.self, SavedLocation.self, PrepSession.self], inMemory: true)
}
