//
//  SettingsView.swift
//  Jeeves
//
//  One settings screen for every API key the app uses, each entered by the
//  user and stored in Keychain — never hardcoded, never in source control.
//  Shared (not private to one feature) since keys span features: Claude
//  powers both the Library's book tools and the Jeeves planner; Google Maps
//  is planner-only; Google Books is library-only.
//

import SwiftUI

struct SettingsView: View {
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

            keySection(
                title: "Google Maps",
                placeholder: "Google Maps API key",
                input: $googleMapsInput,
                hasKey: $hasGoogleMaps,
                explanation: "Optional — gives Jeeves real commute times with live traffic. Without it, the planner uses a default estimate. Enable the Distance Matrix API in Google Cloud Console, then create a key.",
                save: { KeychainService.saveGoogleMapsAPIKey($0) },
                remove: { KeychainService.deleteGoogleMapsAPIKey() }
            )

            calendarSection

            keySection(
                title: "Google Books",
                placeholder: "Google Books API key",
                input: $googleBooksInput,
                hasKey: $hasGoogleBooks,
                explanation: "Optional — a fallback for covers/ISBNs when Open Library has no match. Enable the Books API in Google Cloud Console, then create a key.",
                save: { KeychainService.saveGoogleBooksAPIKey($0) },
                remove: { KeychainService.deleteGoogleBooksAPIKey() }
            )
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
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
