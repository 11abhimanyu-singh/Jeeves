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

    @AppStorage(NotificationService.enabledKey) private var remindersEnabled = true

    @State private var claudeInput = ""
    @State private var hasClaude = KeychainService.hasAPIKey

    @State private var googleBooksInput = ""
    @State private var hasGoogleBooks = KeychainService.hasGoogleBooksAPIKey

    @State private var googleMapsInput = ""
    @State private var hasGoogleMaps = KeychainService.hasGoogleMapsAPIKey

    @State private var clientIDInput = ""
    @State private var hasClientID = KeychainService.hasGoogleClientID
    @State private var isCalendarConnected = KeychainService.isGoogleCalendarConnected
    @State private var isConnecting = false
    @State private var calendarError: String?

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

            remindersSection
                .listRowBackground(Color.surface)

            locationsSection
                .listRowBackground(Color.surface)
        }
        .jeevesFormChrome()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { seedLocationsIfNeeded() }
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
        } header: {
            Text("Reminders")
        } footer: {
            Text("On-device reminders at each commute, gym, and event in your day plan — no account or server needed. You'll be asked to allow notifications the first time a plan is made.")
        }
    }

    // MARK: Saved locations

    private var locationsSection: some View {
        Section {
            ForEach(LocationKind.allCases) { kind in
                if let loc = locations.first(where: { $0.kind == kind }) {
                    NavigationLink { LocationEditView(location: loc) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.rawValue).font(.system(size: 15, weight: .semibold))
                            Text(loc.address.isEmpty ? "No address set" : loc.address)
                                .font(.system(size: 12)).foregroundStyle(loc.address.isEmpty ? .secondary : .primary)
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
        try? modelContext.save()
    }

    // MARK: Google Calendar (OAuth — client ID + connect)

    private var calendarSection: some View {
        Section {
            TextField("iOS OAuth client ID", text: $clientIDInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Save client ID") {
                KeychainService.saveGoogleClientID(clientIDInput)
                hasClientID = true
                clientIDInput = ""
            }
            .disabled(clientIDInput.trimmingCharacters(in: .whitespaces).isEmpty)

            if hasClientID {
                if isConnecting {
                    HStack { ProgressView(); Text("Opening Google…").font(.system(size: 13)).foregroundStyle(.secondary) }
                } else if isCalendarConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Color.sageDeep)
                    Button("Disconnect", role: .destructive) {
                        GoogleOAuthService.shared.disconnect()
                        isCalendarConnected = false
                    }
                } else {
                    Button("Connect Google Calendar") { connect() }
                }
            }
            if let calendarError {
                Text(calendarError).font(.system(size: 12)).foregroundStyle(Color.accentDeep)
            }
        } header: {
            Text("Google Calendar")
        } footer: {
            Text(hasClientID
                 ? "Lets Jeeves import today's events automatically. Read-only."
                 : "Optional — import events from Google Calendar. In Google Cloud Console: enable the Google Calendar API, add the Calendar read-only scope on the OAuth consent screen (and yourself as a test user), then create an OAuth client ID of type iOS with bundle ID abhimanyusingh.me.Jeeves. Paste that client ID here.")
        }
    }

    private func connect() {
        isConnecting = true
        calendarError = nil
        Task {
            do {
                try await GoogleOAuthService.shared.connect()
                isCalendarConnected = true
            } catch {
                calendarError = error.localizedDescription
            }
            isConnecting = false
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
            try? modelContext.save()
        }
    }
}
