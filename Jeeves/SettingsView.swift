//
//  SettingsView.swift
//  Jeeves
//
//  The single place for everything you configure once: API keys/integrations
//  (Claude, Google Maps, Google Books, Google Calendar) and the saved
//  Home/Work/Gym locations. Per-day inputs (today's gym, today's events) live
//  in the Jeeves planning flow, not here — those change daily, this doesn't.
//  Keys are stored in Keychain, never hardcoded or committed.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var locations: [SavedLocation]
    @Query private var dailyPlans: [DailyPlanState]
    @Query(sort: \PlanGenerationLog.startedAt, order: .reverse) private var genLogs: [PlanGenerationLog]

    @AppStorage(NotificationService.enabledKey) private var remindersEnabled = true
    @AppStorage(VoiceNoteSync.syncEnabledKey) private var syncVoiceNotes = true
    @AppStorage(DayPreferences.dayStartKey) private var dayStartMinute = DayPreferences.defaultDayStartMinute
    @AppStorage(DayPreferences.bodyWeightKey) private var bodyWeightKg = DayPreferences.defaultBodyWeightKg

    @State private var claudeInput = ""
    @State private var hasClaude = KeychainService.hasAPIKey

    @State private var googleBooksInput = ""
    @State private var hasGoogleBooks = KeychainService.hasGoogleBooksAPIKey

    @State private var googleMapsInput = ""
    @State private var hasGoogleMaps = KeychainService.hasGoogleMapsAPIKey

    @State private var openAIInput = ""
    @State private var hasOpenAI = KeychainService.hasOpenAIAPIKey

    /// Which of the phone's calendars Jeeves reads. There is no account to
    /// connect any more — iOS owns the accounts, this owns the choice.
    @State private var showDeviceCalendars = false

    var body: some View {
        Form {
            keySection(
                title: "Claude",
                placeholder: "Anthropic API key",
                input: $claudeInput,
                hasKey: $hasClaude,
                explanation: "Powers Jeeves planning, book scanning, and summaries. Get one at console.anthropic.com.",
                save: { KeychainService.saveAPIKey($0) },
                remove: { KeychainService.deleteAPIKey() }
            )
            .listRowBackground(Color.surface)

            keySection(
                title: "Google Maps",
                placeholder: "Google Maps API key",
                input: $googleMapsInput,
                hasKey: $hasGoogleMaps,
                explanation: "Optional — gives Jeeves real commute times with live traffic. Without it, the planner uses a default estimate. Enable the Distance Matrix API in Google Cloud Console, then create a key.",
                save: { KeychainService.saveGoogleMapsAPIKey($0) },
                remove: { KeychainService.deleteGoogleMapsAPIKey() }
            )
            .listRowBackground(Color.surface)

            calendarSection
                .listRowBackground(Color.surface)

            keySection(
                title: "Google Books",
                placeholder: "Google Books API key",
                input: $googleBooksInput,
                hasKey: $hasGoogleBooks,
                explanation: "Optional — a fallback for covers/ISBNs when Open Library has no match. Enable the Books API in Google Cloud Console, then create a key.",
                save: { KeychainService.saveGoogleBooksAPIKey($0) },
                remove: { KeychainService.deleteGoogleBooksAPIKey() }
            )
            .listRowBackground(Color.surface)

            keySection(
                title: "OpenAI (ChatGPT)",
                placeholder: "OpenAI API key (sk-…)",
                input: $openAIInput,
                hasKey: $hasOpenAI,
                explanation: "Optional — used ONLY to run ChatGPT plan evals (an independent judge of Jeeves's plans). Never used to make plans. Needs billing enabled at platform.openai.com.",
                save: { KeychainService.saveOpenAIAPIKey($0) },
                remove: { KeychainService.deleteOpenAIAPIKey() }
            )
            .listRowBackground(Color.surface)

            Section {
                NavigationLink { RoutineCatalogView() } label: {
                    Label("Daily routine", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("Planning")
            } footer: {
                Text("The activities Jeeves plans your day around — their durations, priorities, and what's on or off.")
            }
            .listRowBackground(Color.surface)

            personalSection
            remindersSection
                .listRowBackground(Color.surface)

            voiceSection
                .listRowBackground(Color.surface)

            diagnosticsSection
                .listRowBackground(Color.surface)

            locationsSection
                .listRowBackground(Color.surface)
        }
        .jeevesFormChrome()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDeviceCalendars) { DeviceCalendarsSheet() }
        .onAppear { seedLocationsIfNeeded(); Baseline.seed(into: modelContext); Baseline.regroup(in: modelContext) }
    }

    // MARK: Diagnostics — how the planner is performing

    private var diagnosticsSection: some View {
        let s = PlanDiagnostics.summarize(genLogs)
        return Section {
            if s.total == 0 {
                Text("No plans generated yet.").font(.ui(14)).foregroundStyle(Color.textMuted)
            } else {
                diagRow("Plans generated", "\(s.total)")
                diagRow("Returned successfully", "\(Int((s.successRate * 100).rounded()))%")
                diagRow("Typical time (p50)", "\(String(format: "%.1f", Double(s.p50Ms) / 1000))s")
                diagRow("Slowest 5% (p95)", "\(String(format: "%.1f", Double(s.p95Ms) / 1000))s")
                if s.p50ClaudeMs > 0 || s.p50CommuteMs > 0 {
                    diagRow("  ↳ Claude (p50)", "\(String(format: "%.1f", Double(s.p50ClaudeMs) / 1000))s")
                    diagRow("  ↳ Commute lookups (p50)", "\(String(format: "%.1f", Double(s.p50CommuteMs) / 1000))s")
                }
                if s.offline > 0 { diagRow("Offline fallbacks", "\(s.offline)") }
                if s.abandoned > 0 { diagRow("Never returned", "\(s.abandoned)") }
            }
        } header: {
            Text("Planner diagnostics")
        } footer: {
            Text("How long Jeeves takes to return a plan, and how often it succeeds — recorded on-device. \"Never returned\" counts generations interrupted by a crash or force-quit.")
        }
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.ui(14)).foregroundStyle(Color.textSoft)
            Spacer()
            Text(value).font(.ui(14, weight: .semibold)).foregroundStyle(Color.textPrimary)
        }
    }

    // MARK: You

    /// Two numbers that used to be constants: the day start was a `static let`
    /// in Baseline AND DayPlanner with a third derivation in the prompt, and
    /// bodyweight had no home at all — every bodyweight-loaded set opened at
    /// 75 kg regardless of who was lifting.
    private var personalSection: some View {
        Section {
            Picker("Work starts at", selection: $dayStartMinute) {
                // From waking to 11:00, in half-hours. It cannot start before
                // you are awake: sleep is a fixed 23:00–07:00 anchor, and an
                // earlier choice would schedule work into it.
                ForEach(Array(stride(from: DayPreferences.wakeMinute, through: 11 * 60, by: 30)), id: \.self) { m in
                    Text(DayPreferences.clock(m)).tag(m)
                }
            }
            HStack {
                Text("Body weight")
                Spacer()
                Text("\(Int(bodyWeightKg.rounded())) kg")
                    .font(.ui(14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                Stepper("Body weight", value: $bodyWeightKg, in: 30...250, step: 1)
                    .labelsHidden()
            }
        } header: {
            Text("You")
        } footer: {
            Text("You wake at \(DayPreferences.clock(DayPreferences.wakeMinute)) when sleep ends; work starts when you set it here, and the gap between the two is your morning routine. Body weight pre-fills bodyweight-loaded sets in the lift logger; you can still override it per set.")
        }
    }

    // MARK: Reminders

    private var remindersSection: some View {
        Section {
            Toggle("Plan reminders", isOn: $remindersEnabled)
                .tint(Color.accent)
                .onChange(of: remindersEnabled) { _, on in
                    if on {
                        Task { await NotificationService.requestAuthorization() }
                    } else {
                        NotificationService.clearAll()
                    }
                }
            Button {
                Task { await NotificationService.sendTestReminder(body: nextTaskBody()) }
            } label: {
                Label("Send me a test reminder (5s)", systemImage: "bell.badge")
                    .foregroundStyle(Color.accentDeep)
            }
            .disabled(!remindersEnabled)
        } header: {
            Text("Reminders")
        } footer: {
            Text("On-device reminders at each commute, gym, and event in your day plan — no account or server needed. You'll be asked to allow notifications the first time a plan is made. Tap the button and background the app to see one fire in ~5 seconds.")
        }
    }

    // MARK: Voice notes

    private var voiceSection: some View {
        Section {
            Toggle("Sync voice recordings to iCloud", isOn: $syncVoiceNotes)
                .tint(Color.accent)
        } header: {
            Text("Voice notes")
        } footer: {
            Text("Chat voice notes are transcribed on-device (Indian English). With sync on, recordings mirror to your private iCloud Drive (Jeeves \u{203A} VoiceNotes) so the transcription-quality eval can read them; audio older than 30 days is deleted automatically. Transcripts are always kept. Turn off to keep audio on this phone only.")
        }
    }

    /// The next upcoming task in today's committed plan, for the test reminder.
    private func nextTaskBody() -> String {
        let today = Date().startOfDay
        let cal = Calendar.current
        let nowMinute = cal.component(.hour, from: Date()) * 60 + cal.component(.minute, from: Date())
        if let plan = dailyPlans.first(where: { $0.date == today })?.plan,
           let next = plan.blocks
               .compactMap({ b -> (Int, String)? in
                   guard let s = b.startMinute, s >= nowMinute else { return nil }
                   return (s, b.title)
               })
               .min(by: { $0.0 < $1.0 }) {
            return "Time to start: \(next.1) at \(String(format: "%02d:%02d", next.0 / 60, next.0 % 60))"
        }
        return "Time to start your next task — open Jeeves and plan your day."
    }

    // MARK: Saved locations

    private var locationsSection: some View {
        Section {
            ForEach(LocationKind.allCases) { kind in
                if let loc = locations.first(where: { $0.kind == kind }) {
                    NavigationLink { LocationEditView(location: loc) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.rawValue).font(.ui(15, weight: .semibold))
                            Text(loc.address.isEmpty ? "No address set" : loc.address)
                                .font(.ui(12)).foregroundStyle(loc.address.isEmpty ? .secondary : .primary)
                        }
                    }
                }
            }
        } header: {
            Text("Saved locations")
        } footer: {
            Text("Addresses power real commute times (with a Google Maps key). Any of these work: a street address, a place name, a Plus Code, or lat,lng. Facilities let Jeeves reason — e.g. shower at the gym before an event.")
        }
    }

    private func seedLocationsIfNeeded() {
        for kind in LocationKind.allCases where !locations.contains(where: { $0.kind == kind }) {
            modelContext.insert(SavedLocation(kind: kind))
        }
        modelContext.saveOrLog()
    }

    // MARK: Google Calendar (OAuth — client ID + connect)

    private var calendarSection: some View {
        Section {
            Label("Read from this phone's calendars", systemImage: "calendar")
                .foregroundStyle(Color.textPrimary)
            Button("Choose calendars…") { showDeviceCalendars = true }
        } header: {
            Text("Calendars")
        } footer: {
            Text("Jeeves reads whichever calendars you tick — Outlook, Google, iCloud, any account added to this phone. Add accounts in iOS Settings → Apps → Calendar → Accounts. Read-only, and no separate sign-in: the OAuth connection this used to need is gone.")
        }
    }

    @ViewBuilder
    private func keySection(
        title: String,
        placeholder: String,
        input: Binding<String>,
        hasKey: Binding<Bool>,
        explanation: String,
        save: @escaping (String) -> Void,
        remove: @escaping () -> Void
    ) -> some View {
        Section {
            SecureField(placeholder, text: input)
            Button("Save") {
                save(input.wrappedValue)
                hasKey.wrappedValue = true
                input.wrappedValue = ""
            }
            .disabled(input.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text(title)
        } footer: {
            Text(hasKey.wrappedValue ? "A key is currently saved in Keychain." : explanation)
        }
        if hasKey.wrappedValue {
            Section {
                Button("Remove saved key", role: .destructive) {
                    remove()
                    hasKey.wrappedValue = false
                }
            }
        }
    }
}

// MARK: - Location edit

struct LocationEditView: View {
    @Bindable var location: SavedLocation
    @Environment(\.modelContext) private var modelContext
    @State private var facilitiesText = ""

    var body: some View {
        Form {
            Section {
                TextField("Address, place name, or Plus Code", text: $location.address, axis: .vertical)
            } header: {
                Text("Address")
            } footer: {
                Text("A street address, a place name (\"MLR Convention Centre, Bengaluru\"), a Plus Code, or lat,lng all work.")
            }
            .listRowBackground(Color.surface)
            Section {
                TextField("comma, separated, facilities", text: $facilitiesText, axis: .vertical)
            } header: {
                Text("On-site facilities")
            } footer: {
                Text("What you can do here, e.g. shower, weightlifting, lunch. Jeeves uses these to reason about chaining trips.")
            }
            .listRowBackground(Color.surface)
        }
        .jeevesFormChrome()
        .navigationTitle(location.kind.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { facilitiesText = location.facilities.joined(separator: ", ") }
        .onDisappear {
            location.facilities = facilitiesText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            modelContext.saveOrLog()
        }
    }
}
