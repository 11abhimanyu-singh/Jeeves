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
    /// Set when chat is presented as a modal from the floating bubble — it
    /// renders a minimise control that drops back to the bubble. Nil when the
    /// view is embedded somewhere that owns its own dismissal.
    var onMinimise: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Query private var dailyPlans: [DailyPlanState]
    @Query private var events: [DailyEvent]
    @Query private var locations: [SavedLocation]
    @Query private var prepSessions: [PrepSession]
    @Query private var routineActivities: [RoutineActivity]
    // Persisted conversation, oldest first — survives tab switches and restarts.
    @Query(sort: \ChatTurn.timestamp, order: .forward) private var allTurns: [ChatTurn]

    @State private var inputText = ""
    @State private var isSending = false
    @State private var isPlanning = false
    @State private var errorText: String?
    @State private var showSetup = false
    @State private var showSettings = false

    // In-chat ticket upload → event ingestion.
    @State private var photoItem: PhotosPickerItem?
    @StateObject private var voice = VoiceRecorder()
    @State private var isReadingTicket = false
    @State private var detectedDraft: EventDraft?

    private var today: Date { Date().startOfDay }
    private var toolExecutor: ChatToolExecutor { ChatToolExecutor(modelContext: modelContext) }
    private var todayPlanState: DailyPlanState? { dailyPlans.first { $0.date == today } }
    private var todayEvents: [DailyEvent] { events.filter { $0.date == today }.sorted { $0.startMinute < $1.startMinute } }

    // Session = a rolling 45-minute window. Turns older than this are pruned on
    // open, so returning after a break shows a clean window, not a long history.
    private static let sessionWindow: TimeInterval = 45 * 60
    // "New chat" moves this marker instead of deleting anything — history is
    // retained in the store (and exported for the chat eval); the screen and
    // the LLM only see the current session.
    @AppStorage("chatSessionStart") private var chatSessionStart: Double = 0
    private var turns: [ChatTurn] {
        let cutoff = max(Date().addingTimeInterval(-Self.sessionWindow),
                         Date(timeIntervalSince1970: chatSessionStart))
        return allTurns.filter { $0.timestamp >= cutoff }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.textPrimary.opacity(0.14))
            planMyDayBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if turns.isEmpty {
                            Text("Tell Jeeves about your day, or tap Plan my day. Jeeves reasons like a human planner — chaining trips, using the gym shower, moving lunch near your event — not just packing blocks into gaps.")
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color.textMuted)
                                .multilineTextAlignment(.center)
                                .padding(.top, 24).padding(.horizontal, 24)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        ForEach(turns) { turn in
                            turnView(turn).id(turn.id)
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
                .scrollDismissesKeyboard(.interactively)
                // Open at the most recent message, not the top.
                .defaultScrollAnchor(.bottom)
                .onChange(of: turns.count) { _, _ in
                    guard let last = turns.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear {
                    if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider().overlay(Color.textPrimary.opacity(0.1))
            inputBar
        }
        .background(Color.bg)
        // Tap anywhere on the conversation to dismiss the keyboard.
        .onTapGesture { dismissKeyboard() }
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
            if let onMinimise {
                Button(action: onMinimise) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.textSoft)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimise chat")
            }
            Circle()
                .fill(Color.accent)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "sparkles").foregroundStyle(.white).font(.system(size: 13)))
            Text("Jeeves").font(.heading(18)).foregroundStyle(Color.textPrimary)
            Spacer()
            // New chat = start a fresh session. Older turns stay in the store
            // (they feed the chat eval) — they just leave the screen.
            if !turns.isEmpty {
                Button { startNewSession() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 16)).foregroundStyle(Color.textSoft)
                }
            }
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

    // MARK: Turn rendering

    @ViewBuilder
    private func turnView(_ turn: ChatTurn) -> some View {
        if let plan = turn.plan {
            PlanTimelineCard(plan: plan, isOffline: turn.isOfflinePlan)
        } else {
            bubble(for: turn)
        }
    }

    private func bubble(for turn: ChatTurn) -> some View {
        HStack {
            if turn.isUser { Spacer(minLength: 40) }
            VStack(alignment: .trailing, spacing: 6) {
                // Uploaded ticket image, shown in-thread so the user sees what
                // Jeeves is reading.
                if let data = turn.imageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if !turn.content.isEmpty {
                    Text(turn.content)
                        .font(.system(size: 14.5))
                        .foregroundStyle(turn.isUser ? .white : Color.textPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 16).fill(turn.isUser ? Color.accent : Color.surface))
                }
            }
            if !turn.isUser { Spacer(minLength: 40) }
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

            // Voice note: tap to record (en-IN transcription), tap again to
            // stop — the transcript lands in the field for a glance-and-send.
            Button { voiceTapped() } label: {
                Group {
                    switch voice.phase {
                    case .idle:
                        Image(systemName: "mic")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.textSoft)
                    case .recording:
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color(red: 0.70, green: 0.23, blue: 0.18))
                            .symbolEffect(.pulse, options: .repeating)
                    case .transcribing:
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.bottom, 4)
                .frame(width: 26)
            }
            .buttonStyle(.plain)
            .disabled(voice.phase == .transcribing)

            TextField(voice.phase == .recording ? "Listening… tap ⏹ to finish" : "Message Jeeves…",
                      text: $inputText, axis: .vertical)
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

    /// One button, three states: start recording → stop & transcribe → (spinner).
    private func voiceTapped() {
        switch voice.phase {
        case .idle:
            Task {
                await voice.start()
                // Surface a denied-permission / failed-start message; otherwise
                // the mic button just silently does nothing.
                if let e = voice.errorText { errorText = e }
            }
        case .recording:
            Task {
                if let r = await voice.stopAndTranscribe(contextualStrings: voiceVocabulary) {
                    inputText = r.transcript
                    // Persist the note — audio + transcript are the eval corpus.
                    modelContext.insert(VoiceNote(date: Date(), durationSec: r.duration,
                                                  transcript: r.transcript,
                                                  audioFileName: r.fileName))
                    modelContext.saveOrLog()
                } else if let e = voice.errorText {
                    errorText = e
                }
            }
        case .transcribing:
            break
        }
    }

    /// Bias the recognizer toward this user's world — exercise names, app
    /// vocabulary, and the titles of their actual events (Indian names and
    /// places are exactly what generic models fumble).
    private var voiceVocabulary: [String] {
        var words = ["Jeeves", "tonnage", "Couch to 5K", "incline", "front squat", "check-in"]
        words += LiftExercise.library.map(\.name)
        words += events.map(\.title)
        // Proper nouns are where the recognizer fails (eval: "JLR River term")
        // — bias it with the user's actual venues and saved addresses.
        words += events.map(\.destinationAddress).filter { !$0.isEmpty }
        words += locations.map(\.address).filter { !$0.isEmpty }
        return words
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && !isPlanning
    }

    // MARK: Persisted-turn helpers

    @discardableResult
    private func addTurn(role: ChatMessage.Role, _ content: String, plan: GeneratedPlan? = nil, isOfflinePlan: Bool = false, imageData: Data? = nil) -> ChatTurn {
        let turn = ChatTurn(
            role: role.rawValue, content: content, day: today,
            planJSON: plan.flatMap(ChatTurn.encodePlan), isOfflinePlan: isOfflinePlan, imageData: imageData
        )
        modelContext.insert(turn)
        modelContext.saveOrLog()
        return turn
    }

    /// "New chat": move the session marker forward. Nothing is deleted — the
    /// full history stays in the store for the eval pipeline.
    private func startNewSession() {
        chatSessionStart = Date().timeIntervalSince1970
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Prior text turns (no plans), as the chat API's conversation history.
    private var chatHistory: [ChatMessage] {
        turns.filter { $0.plan == nil && !$0.content.isEmpty }
            .map { ChatMessage(role: $0.isUser ? .user : .assistant, content: $0.content) }
    }

    // MARK: Agentic chat

    /// The conversational agent. The model can add events, set the gym, and
    /// build the day's plan through tools — so typing "dinner at 8, plan
    /// tomorrow" actually creates the event and generates the schedule,
    /// instead of pointing the user at the button. Tool execution runs here
    /// because it needs SwiftData and today's context.
    private func sendChat() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let priorHistory = chatHistory
        let stateNote = toolExecutor.stateNote()
        addTurn(role: .user, text)
        inputText = ""
        errorText = nil
        dismissKeyboard()
        isSending = true

        Task {
            // Hold a background assertion: an agentic turn can call plan_day,
            // which is slow, so it must survive the user switching away.
            let outcome = await BackgroundActivity.run("jeeves-chat") { () -> Result<JeevesChatService.AgenticReply, Error> in
                do {
                    let reply = try await JeevesChatService.sendAgentic(
                        history: priorHistory, newMessage: text, stateNote: stateNote,
                        execute: { call in await toolExecutor.run(call) }
                    )
                    return .success(reply)
                } catch {
                    return .failure(error)
                }
            }
            switch outcome {
            case .success(let reply):
                if !reply.text.isEmpty { addTurn(role: .assistant, reply.text) }
                // A claim that survived the challenge is a real incident — the
                // digest must see it, not just the user who read the reply.
                if reply.unverifiedClaim {
                    EventLog.log(.chatUnverifiedClaim,
                                 "reply claimed a change with no tool call: \(reply.text.prefix(160))",
                                 context: modelContext)
                }
                // Any plans the agent built, as timeline cards after the reply.
                for made in reply.plans {
                    addTurn(role: .assistant, "", plan: made.plan, isOfflinePlan: made.isOffline)
                }
                // Never leave the turn visibly silent: if the model exhausted the
                // tool-loop with no closing text and no plan, still acknowledge.
                if reply.text.isEmpty && reply.plans.isEmpty {
                    addTurn(role: .assistant, "Done — anything else?")
                }
            case .failure(let error):
                errorText = error.localizedDescription
                // The failure must live in the TRANSCRIPT, not just a banner:
                // a user who answered "20" and got twelve minutes of silence
                // had hit exactly this path — the error flashed and vanished,
                // the conversation kept a hole, and the model's next turn had
                // no idea it ever dropped one.
                addTurn(role: .assistant,
                        "That one didn't go through (\(error.localizedDescription)) — say \u{201C}try again\u{201D} and I'll pick up where we left off.")
                EventLog.log(.chatError, error.localizedDescription, context: modelContext)
            }
            isSending = false
        }
    }

    // MARK: Chat tools

    /// Dispatches one tool call from the agent to its handler — and records
    /// every call in the event log, so EVERY conversation is a trajectory
    /// artifact: transcript + tool calls + store changes, cross-checkable by
    /// the trajectory audit ("does the story told match the state left?").
    @MainActor
    // MARK: Plan generation

    private func planMyDay() {
        errorText = nil
        dismissKeyboard()
        isPlanning = true
        let userContext = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userContext.isEmpty {
            addTurn(role: .user, userContext)
            inputText = ""
        }

        Task {
            // Hold a background assertion so the whole flow (anchor extraction +
            // planning) survives the user switching away mid-request.
            let result = await BackgroundActivity.run("plan-my-day") { () -> PlanCoordinator.Result in
                // 1. Pull any events/gym mentioned in the message into real
                //    anchors, so "MLR at 7pm, plan my day" works without manual
                //    event entry.
                let planEvents = await extractAndCreateAnchors(from: userContext)
                // 2. Generate (Claude, with deterministic fallback) via the
                //    shared coordinator — same call the Day Planner uses.
                return await PlanCoordinator.generateLogged(.init(
                    userMessage: userContext,
                    hasGym: todayPlanState?.hasGymToday ?? false,
                    gymMinute: todayPlanState?.gymMinute,
                    events: planEvents,
                    locations: locations,
                    prepSessions: prepSessions,
                    routine: Baseline.routine(from: routineActivities),
                    adherenceNote: AdherenceHistory.planningNote(context: modelContext, for: today),
                    planDate: today
                ), context: modelContext, trigger: .chat)
            }
            // 3. COMMIT it to the Day Planner for today so it persists across
            //    launches and shows on the planner — not just here in chat.
            toolExecutor.commitPlan(result.plan, isOffline: result.isOffline, on: today)
            // If they backgrounded the app while it planned, tell them it's ready.
            await NotificationService.notifyPlanReady(isOffline: result.isOffline)

            if result.isOffline {
                addTurn(role: .assistant, "I couldn't reach the planning service, so here's an offline plan from the built-in scheduler.\(result.error.map { " (\($0))" } ?? "")")
            } else {
                addTurn(role: .assistant, result.plan.summary)
            }
            addTurn(role: .assistant, "", plan: result.plan, isOfflinePlan: result.isOffline)
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
            toolExecutor.resolveEventDestinationIfLink(event)
            created.append(event)
        }

        // Gym, only if the message actually mentioned it.
        if let gymToday = anchors.gymToday {
            let state = DailyPlanState.fetchOrCreate(for: today, in: modelContext)
            state.hasGymToday = gymToday
            if let gt = anchors.gymTime.flatMap(GeneratedBlock.minutes(from:)) { state.gymMinute = gt }
        }

        modelContext.saveOrLog()
        return todayEvents + created
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
        guard let data = try? await item.loadTransferable(type: Data.self), let uiImage = UIImage(data: data) else {
            errorText = "Couldn't load that image."
            isReadingTicket = false
            return
        }
        // Show the uploaded image in the thread so it's clear what Jeeves is reading.
        let shrunk = uiImage.jpegData(compressionQuality: 0.5) ?? data
        addTurn(role: .user, "", imageData: shrunk)
        do {
            let detected = try await EventVisionService.detectEvent(in: uiImage)
            detectedDraft = EventDraft(detected: detected)
        } catch {
            errorText = error.localizedDescription
        }
        isReadingTicket = false
    }

    private func addEventFromChat(_ draft: EventDraft) {
        let event = DailyEvent(
            date: draft.date.startOfDay, title: draft.title,
            startMinute: draft.startMinute, endMinute: draft.endMinute,
            destinationAddress: draft.address, outboundStart: draft.outboundStart, source: draft.source
        )
        modelContext.insert(event)
        modelContext.saveOrLog()
        toolExecutor.resolveEventDestinationIfLink(event)
        addTurn(role: .assistant, "Added to today: \(draft.title) at \(hhmm(draft.startMinute)). Tap Plan my day and I'll fit everything around it.")
    }

    private func hhmm(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

// MARK: - Plan timeline card

struct PlanTimelineCard: View {
    let plan: GeneratedPlan
    let isOffline: Bool
    // Adherence: effective outcome per block (keyed by AdherenceEngine.key) and
    // a tap handler. When onToggle is nil the card is read-only (e.g. in chat).
    var outcomes: [String: BlockOutcome] = [:]
    var onToggle: ((GeneratedBlock, BlockOutcome) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isOffline ? "OFFLINE PLAN" : "TODAY'S PLAN")
                    .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(Color.accent)
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
                    .font(.serif(15))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = block.note, !note.isEmpty {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if let onToggle {
                let outcome = outcomes[AdherenceEngine.key(block)] ?? .unknown
                Button { onToggle(block, outcome) } label: { checkbox(outcome) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .opacity(outcomes[AdherenceEngine.key(block)] == .skipped ? 0.55 : 1)
    }

    private func checkbox(_ o: BlockOutcome) -> some View {
        Image(systemName: o == .done ? "checkmark.circle.fill" : (o == .skipped ? "xmark.circle" : "circle"))
            .font(.system(size: 20))
            .foregroundStyle(o == .done ? Color.sageDeep : (o == .skipped ? Color.textMuted : Color.surfaceDeep))
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
        .modelContainer(for: [DailyPlanState.self, DailyEvent.self, SavedLocation.self, PrepSession.self, ChatTurn.self], inMemory: true)
}
