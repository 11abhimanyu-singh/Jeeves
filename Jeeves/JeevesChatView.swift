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

    @Query private var trips: [Trip]
    @Query private var segments: [TravelSegment]

    @State private var inputText = ""
    @State private var isSending = false
    @State private var isPlanning = false
    @State private var errorText: String?
    @State private var showSetup = false
    @State private var showSettings = false
    /// Non-nil while the activity picker is up, carrying the day it is for.
    /// `.sheet(item:)` needs identity and a bare Date has none.
    struct PickerRequest: Identifiable { let id: Date; var day: Date { id } }
    @State private var pickerDay: PickerRequest?
    /// What the executor is doing RIGHT NOW, named. A bare spinner through
    /// four tool calls reads as a hang.
    @State private var activeTool: String?

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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if turns.isEmpty {
                            Text("Tell Jeeves about your day, or tap Plan my day. Jeeves reasons like a human planner — chaining trips, using the gym shower, moving lunch near your event — not just packing blocks into gaps.")
                                .font(.ui(13.5))
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
                                ProgressView().controlSize(.small)
                                Text(planningStatus)
                                    .font(.ui(12.5)).foregroundStyle(Color.textMuted)
                                    .contentTransition(.opacity)
                            }
                            .padding(.leading, 4)
                            .id("activity")
                        }

                        if let errorText {
                            Text(errorText).font(.ui(12.5)).foregroundStyle(Color.accentDeep)
                        }
                    }
                    .padding(16)
                    // The keyboard dismisses by tapping the CONVERSATION, and
                    // only the conversation. This gesture used to live on the
                    // root VStack — which contains the composer — so it sat
                    // above the mic, the attach button and the field and
                    // competed with every one of them for the tap. That, not
                    // the buttons themselves, is why they felt dead.
                    //
                    // SIMULTANEOUS, not exclusive. As `onTapGesture` it also
                    // swallowed taps aimed at controls INSIDE the conversation:
                    // the morning card's gym switch was completely dead while
                    // the Buttons beside it worked, because a Button installs a
                    // higher-priority gesture and a Toggle does not. Anything
                    // that isn't a Button — switches, pickers, sliders — loses
                    // that race. Running both means the control gets its tap
                    // and the keyboard still goes away.
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
                }
                .scrollDismissesKeyboard(.interactively)
                // Open at the most recent message, not the top.
                .defaultScrollAnchor(.bottom)
                .onChange(of: turns.count) { _, _ in
                    guard let last = turns.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear {
                    postMorningOfferIfNeeded()
                    if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            suggestionChips
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
        .sheet(item: $pickerDay) { request in
            ActivityPickerSheet(day: request.day) { chosenDay in
                pickerDay = nil
                planPickedDay(chosenDay)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await readTicket(item); photoItem = nil }
        }
    }

    /// Three targets, not five. New chat, Today's anchors and Settings were
    /// three separate 16pt glyphs crowded into one row — the same undersized
    /// target problem as the mic, three times over. They live in one menu now,
    /// and the space that frees carries a status line: Jeeves already builds
    /// this summary for every turn's state note, so the screen can answer
    /// "what do you know about me?" before being asked.
    private var header: some View {
        HStack(spacing: 6) {
            if let onMinimise {
                Button(action: onMinimise) {
                    Image(systemName: "chevron.down")
                        .font(.ui(16, weight: .semibold))
                        .foregroundStyle(Color.textSoft)
                        .frame(width: Self.tapTarget, height: Self.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimise chat")
            }
            Circle()
                .fill(Color.accent)
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: "sparkles").foregroundStyle(.white).font(.ui(13)))
                .padding(.leading, onMinimise == nil ? 8 : 0)

            VStack(alignment: .leading, spacing: 0) {
                Text("Jeeves").font(.heading(18)).foregroundStyle(Color.textPrimary)
                Text(statusLine)
                    .font(.ui(11.5)).foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            Menu {
                if !turns.isEmpty {
                    // New chat = start a fresh session. Older turns stay in the
                    // store (they feed the chat eval) — they just leave the screen.
                    Button { startNewSession() } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                }
                // Today's anchors (gym + events). NOT a calendar glyph: that one
                // means "pick a date" everywhere else, and wearing it here made
                // three screens promise three different things with one icon.
                Button { showSetup = true } label: {
                    Label("Today's anchors", systemImage: "slider.horizontal.3")
                }
                // Gear = standing configuration (keys, integrations, locations).
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.ui(17, weight: .semibold))
                    .foregroundStyle(Color.textSoft)
                    .frame(width: Self.tapTarget, height: Self.tapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 6)
    }

    /// What Jeeves is holding, in one line. Read from the store, never from
    /// the conversation — the same rule the chat itself now follows.
    private var statusLine: String {
        var parts: [String] = []
        let upcoming = trips.filter { $0.endDate >= today }.sorted { $0.startDate < $1.startDate }
        let legs = segments.filter { $0.day >= today }.count
        if legs > 0 { parts.append("\(legs) journey\(legs == 1 ? "" : "s")") }
        if let next = upcoming.first {
            let days = Calendar.current.dateComponents([.day], from: today, to: next.startDate).day ?? 0
            if days <= 0 {
                parts.append("\(next.title) now")
            } else {
                parts.append("\(next.title) in \(days) day\(days == 1 ? "" : "s")")
            }
        }
        if parts.isEmpty {
            let n = todayEvents.count
            parts.append(n == 0 ? "Nothing on today" : "\(n) event\(n == 1 ? "" : "s") today")
        }
        return parts.joined(separator: " · ")
    }

    /// "Plan my day" used to hold a permanent full-width bar above the
    /// conversation — roughly 60pt of vertical space, on every turn, forever.
    /// As chips it keeps its prominence on an empty thread and gets out of the
    /// way the moment you start typing.
    @ViewBuilder
    private var suggestionChips: some View {
        if !isSending && !isPlanning && !isReadingTicket
            && inputText.trimmingCharacters(in: .whitespaces).isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button(action: planMyDay) {
                        HStack(spacing: 5) {
                            Image(systemName: "wand.and.stars").font(.ui(12, weight: .semibold))
                            Text("Plan my day").font(.ui(13.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(Color.accent))
                    }
                    .buttonStyle(.plain)

                    ForEach(contextualSuggestions, id: \.self) { text in
                        Button { inputText = text; sendChat() } label: {
                            Text(text)
                                .font(.ui(13.5))
                                .foregroundStyle(Color.textPrimary)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 36)
                                .background(
                                    Capsule().fill(Color.surface)
                                        .overlay(Capsule().stroke(Color.textPrimary.opacity(0.11)))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 8)
        }
    }

    /// Offers that depend on what is actually on file, so a chip never
    /// proposes something the store can't answer.
    private var contextualSuggestions: [String] {
        var out: [String] = []
        if segments.contains(where: { $0.day >= today }) { out.append("Show my upcoming journeys") }
        if todayPlanState?.plan != nil { out.append("What's left today?") }
        else if !todayEvents.isEmpty { out.append("What's on today?") }
        return Array(out.prefix(2))
    }

    // MARK: Turn rendering

    @ViewBuilder
    private func turnView(_ turn: ChatTurn) -> some View {
        if let plan = turn.plan {
            PlanTimelineCard(plan: plan, isOffline: turn.isOfflinePlan)
        } else if let day = turn.morningPromptDay {
            // The morning offer renders as a card rather than a bubble. It is
            // the interface, not a description of one — the alternative was
            // asking the user to type back a list of names at 7am.
            // Same path the picker sheet uses: the card stores the selection,
            // the executor plans it. One planning route, reached two ways.
            MorningPickerCard(day: day, onPlan: planPickedDay)
        } else {
            bubble(for: turn)
        }
    }

    private func bubble(for turn: ChatTurn) -> some View {
        VStack(alignment: turn.isUser ? .trailing : .leading, spacing: 8) {
            speechBubble(for: turn)
            // The old value lives in a slot, not in a sentence. Three eval
            // scenarios failed because the reply dropped it while the tool
            // result underneath still had it — prose makes that easy, a card
            // with an empty half does not.
            ForEach(turn.receipts) { receipt in
                ReceiptCard(receipt: receipt)
            }
        }
        .frame(maxWidth: .infinity, alignment: turn.isUser ? .trailing : .leading)
    }

    private func speechBubble(for turn: ChatTurn) -> some View {
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
                        .font(.ui(14.5))
                        .foregroundStyle(turn.isUser ? .white : Color.textPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 16).fill(turn.isUser ? Color.accent : Color.surface))
                }
            }
            if !turn.isUser { Spacer(minLength: 40) }
        }
    }

    /// Apple's minimum touch target. The mic used to be `.frame(width: 26)`
    /// and attach a bare 22pt glyph with no frame at all — roughly half of
    /// this, which is why they missed even when nothing was intercepting them.
    static let tapTarget: CGFloat = 44

    @ViewBuilder
    private var inputBar: some View {
        if voice.phase == .idle {
            composerIdle
        } else {
            composerRecording
        }
    }

    private var composerIdle: some View {
        HStack(alignment: .bottom, spacing: 2) {
            // Attach a ticket screenshot → Jeeves reads it and drafts an event.
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo")
                    .font(.ui(20))
                    .foregroundStyle(Color.textSoft)
                    .frame(width: Self.tapTarget, height: Self.tapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Attach a ticket")

            // Voice note: tap to record (en-IN transcription). Stopping and
            // cancelling both live in the recording bar, so this is a single
            // unambiguous action rather than a button that means three things.
            Button { voiceTapped() } label: {
                Image(systemName: "mic")
                    .font(.ui(20))
                    .foregroundStyle(Color.textSoft)
                    .frame(width: Self.tapTarget, height: Self.tapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Record a voice note")

            TextField("Message Jeeves…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .font(.ui(15))
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 15)
                .frame(minHeight: Self.tapTarget)
                .background(
                    RoundedRectangle(cornerRadius: 22).fill(Color.surface)
                        .overlay(RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.textPrimary.opacity(0.09)))
                )

            Button(action: sendChat) {
                Image(systemName: "arrow.up")
                    .font(.ui(17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(canSend ? Color.accent : Color.textMuted.opacity(0.35)))
                    .frame(width: Self.tapTarget, height: Self.tapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.bg)
    }

    /// Recording had no way out: the only exit was stop-and-transcribe, so a
    /// mistaken tap — likely, at 26pt — cost you a transcription you didn't
    /// want. VoiceRecorder has had `cancel()` and `elapsed` all along; nothing
    /// was calling them.
    private var composerRecording: some View {
        HStack(spacing: 2) {
            Button { voice.cancel() } label: {
                Text("Cancel")
                    .font(.ui(14.5))
                    .foregroundStyle(Color.textMuted)
                    .padding(.horizontal, 10)
                    .frame(height: Self.tapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(voice.phase == .transcribing)

            HStack(spacing: 10) {
                if voice.phase == .transcribing {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…")
                        .font(.ui(14.5)).foregroundStyle(Color.textMuted)
                } else {
                    // A live clock, so a recording that silently failed to
                    // start is visible as one that never advances.
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Text(Self.clock(voice.elapsed))
                            .font(.ui(14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.accentDeep)
                    }
                    RecordingWave()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15)
            .frame(minHeight: Self.tapTarget)
            .background(
                RoundedRectangle(cornerRadius: 22).fill(Color.surface)
                    .overlay(RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.accent.opacity(0.35)))
            )

            Button { voiceTapped() } label: {
                Image(systemName: "stop.fill")
                    .font(.ui(15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.accentDeep))
                    .frame(width: Self.tapTarget, height: Self.tapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(voice.phase == .transcribing)
            .accessibilityLabel("Stop and transcribe")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.bg)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
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
    private func addTurn(role: ChatMessage.Role, _ content: String, plan: GeneratedPlan? = nil, isOfflinePlan: Bool = false, imageData: Data? = nil, receiptsJSON: String? = nil) -> ChatTurn {
        let turn = ChatTurn(
            role: role.rawValue, content: content, day: today,
            planJSON: plan.flatMap(ChatTurn.encodePlan), isOfflinePlan: isOfflinePlan,
            imageData: imageData, receiptsJSON: receiptsJSON
        )
        modelContext.insert(turn)
        modelContext.saveOrLog()
        return turn
    }

    /// Jeeves has already made the offer by the time you get here.
    ///
    /// The point of the redesign is that opening chat in the morning shows you
    /// a list to choose from, not an empty box waiting for you to ask. The
    /// notification is only the doorbell — this is the thing behind the door,
    /// and it has to work identically when you arrive by tapping the bubble.
    ///
    /// Scoped to the visible session, not all of history: a card posted at
    /// 07:00 has scrolled out of the 45-minute window by evening, and a day
    /// still unplanned at 8pm should be offered again rather than silently
    /// counted as asked.
    private func postMorningOfferIfNeeded() {
        guard !TravelGuard.isTravelDay(today, context: modelContext) else { return }
        let showing = turns.contains { $0.morningPromptDay?.startOfDay == today }
        guard MorningPromptService.shouldPost(
            hasPlan: todayPlanState?.plan != nil,
            candidateCount: MorningPrompt.candidates(routine: routineActivities, on: today).count,
            alreadyShowing: showing) else { return }

        let turn = ChatTurn(role: ChatMessage.Role.assistant.rawValue, content: "",
                            day: today, morningPromptDay: today)
        modelContext.insert(turn)
        modelContext.saveOrLog("morning.offer")
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

        // Receipts are collected from the TOOL RESULTS as they come back, so
        // the card can never disagree with what actually happened.
        let collected = ToolReceiptCollector()
        // ONE executor for the whole turn. `toolExecutor` is a computed
        // property that builds a fresh instance on every access, so anything a
        // tool records on it — like a request to show the activity picker —
        // would be thrown away the moment the next line asked for it again.
        let executor = toolExecutor

        Task {
            // Hold a background assertion: an agentic turn can call plan_day,
            // which is slow, so it must survive the user switching away.
            let outcome = await BackgroundActivity.run("jeeves-chat") { () -> Result<JeevesChatService.AgenticReply, Error> in
                do {
                    let reply = try await JeevesChatService.sendAgentic(
                        history: priorHistory, newMessage: text, stateNote: stateNote,
                        execute: { call in
                            activeTool = ToolActivity.label(for: call.name, input: call.input)
                            let result = await executor.run(call)
                            collected.add(tool: call.name, result: result.text)
                            activeTool = nil
                            return result
                        }
                    )
                    return .success(reply)
                } catch {
                    return .failure(error)
                }
            }
            activeTool = nil
            switch outcome {
            case .success(let reply):
                if !reply.text.isEmpty {
                    addTurn(role: .assistant, reply.text,
                            receiptsJSON: ChatReceipt.encode(collected.receipts))
                }
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
                // A tool asked for the picker: present it after the reply is on
                // screen, so the user reads the sentence and then sees the list.
                if let day = executor.pendingPickerDate { pickerDay = .init(id: day) }
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
                let selection = todayPlanState?.activitySelection ?? .routine
                return await PlanCoordinator.generateLogged(.init(
                    userMessage: userContext,
                    hasGym: todayPlanState?.hasGymToday ?? false,
                    gymMinute: todayPlanState?.gymMinute,
                    events: planEvents,
                    locations: locations,
                    prepSessions: prepSessions,
                    routine: Baseline.routine(from: routineActivities, selection: selection, on: today),
                    gymSession: Baseline.gymSession(from: routineActivities),
                    adherenceNote: AdherenceHistory.planningNote(context: modelContext, for: today),
                    planDate: today,
                    // Tapping this at 12:45 asks for the rest of today, not a
                    // fresh 08:00–20:30 day on top of the one already spent.
                    existingPlan: todayPlanState?.plan,
                    blankDay: selection.isBlankDay
                ), context: modelContext, trigger: .chat)
            }
            // 3. COMMIT it to the Day Planner for today so it persists across
            //    launches and shows on the planner — not just here in chat.
            await toolExecutor.commitPlan(result, on: today)
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

    /// Plan a day from the boxes the user just ticked. Goes through the same
    /// executor path plan_day uses, so a day chosen by tapping is built exactly
    /// like one chosen by asking.
    private func planPickedDay(_ day: Date) {
        isPlanning = true
        let executor = toolExecutor
        Task {
            let result = await BackgroundActivity.run("plan-my-day") {
                await executor.planDay(day, note: "Plan only the activities the user ticked.")
            }
            await NotificationService.notifyPlanReady(isOffline: result.isOffline)
            if result.isOffline {
                addTurn(role: .assistant, "I couldn't reach the planning service, so here's an offline plan built from what you picked.\(result.error.map { " (\($0))" } ?? "")")
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
        if isReadingTicket { return "Reading your ticket…" }
        // The running tool wins: it is the most specific true thing available,
        // and it makes the read path visible.
        if let activeTool { return activeTool }
        if isPlanning { return "Jeeves is planning your day…" }
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
    /// Starting a timed session. Nil in read-only contexts (chat, past days).
    var onStart: ((GeneratedBlock) -> Void)? = nil
    /// Which blocks may be started — measurable, today, not already logged.
    var startableKeys: Set<String> = []
    /// Show Jeeves's reasoning above the timeline.
    ///
    /// Opt-in because chat already prints the summary as its own turn beside
    /// this card, so switching it on there would say it twice. On the PLANNER
    /// it appeared nowhere at all: every plan has carried a summary the whole
    /// time — on 4 Aug it read "job applications and prep practice keep getting
    /// skipped in these late slots anyway, I'd suggest we try them first thing
    /// tomorrow morning instead" — and it was generated, stored, and never
    /// shown to anyone who wasn't in chat.
    var showsSummary: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isOffline ? "OFFLINE PLAN" : "TODAY'S PLAN")
                    .font(.ui(11, weight: .semibold)).tracking(1.2).foregroundStyle(Color.accentDeep)
                Spacer()
                if let boundary = plan.boundaryTime {
                    Text("until \(boundary)").font(.ui(11, weight: .semibold)).foregroundStyle(Color.accentDeep)
                }
            }
            .padding(.bottom, 10)

            // Above the timeline, because it is context for the day rather than
            // a footnote to it — and because the dropped/shortened lines below
            // are what the planner could NOT do, which is a worse thing to read
            // first than what it decided.
            if showsSummary, !plan.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(plan.summary)
                    .font(.serif(14)).foregroundStyle(Color.textSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }

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
                .font(.ui(12.5, weight: .semibold))
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
                    Text(note).font(.ui(11.5)).foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if let onStart, startableKeys.contains(AdherenceEngine.key(block)) {
                Button { onStart(block) } label: {
                    Image(systemName: "play.fill")
                        .font(.ui(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.accent))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start \(block.title)")
            }
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
            .font(.ui(20))
            .foregroundStyle(o == .done ? Color.sageDeep : (o == .skipped ? Color.textMuted : Color.surfaceDeep))
    }

    private func changeLine(label: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.ui(10, weight: .semibold)).foregroundStyle(Color.textMuted)
            Text(items.joined(separator: ", ")).font(.ui(12.5)).foregroundStyle(Color.textSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    JeevesChatView()
        .modelContainer(for: [DailyPlanState.self, DailyEvent.self, SavedLocation.self, PrepSession.self, ChatTurn.self], inMemory: true)
}
