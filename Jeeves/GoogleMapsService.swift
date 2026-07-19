//
//  GoogleMapsService.swift
//  Jeeves
//
//  Real driving commute times with live traffic (PRD §5.4, §6) via the
//  Google Routes API (computeRoutes). The older Distance Matrix API is a
//  legacy product Google no longer enables for new projects, so this uses
//  the current Routes API instead. Requires a user-supplied, Keychain-
//  stored Maps key with the Routes API enabled. Everything is best-effort:
//  no key, no network, or an un-routable address returns nil, and the
//  planner falls back to the user's default commute minutes.
//

import Foundation

enum GoogleMapsService {
    private static let endpoint = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!

    /// Live-traffic driving minutes between two addresses/place names, or nil
    /// if it can't be determined (missing key, bad address, network/API error).
    static func commuteMinutes(from origin: String, to destination: String) async -> Int? {
        let o = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty, !d.isEmpty,
              let apiKey = KeychainService.loadGoogleMapsAPIKey(), !apiKey.isEmpty else { return nil }

        let body: [String: Any] = [
            "origin": ["address": o],
            "destination": ["address": d],
            "travelMode": "DRIVE",
            "routingPreference": "TRAFFIC_AWARE",
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("routes.duration", forHTTPHeaderField: "X-Goog-FieldMask")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        struct Response: Decodable {
            struct Route: Decodable { let duration: String? } // e.g. "2491s"
            let routes: [Route]
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let durationString = decoded.routes.first?.duration,
                  let seconds = Double(durationString.replacingOccurrences(of: "s", with: "")) else { return nil }
            return Int((seconds / 60).rounded())
        } catch {
            return nil
        }
    }

    /// Resolves the commute legs a plan needs, keyed "From→To" to match the
    /// prompt's expected format (PlanRequest.commuteEstimates). Silently omits
    /// any leg it can't resolve; the planner uses its default for those.
    static func commuteEstimates(legs: [(label: String, from: String, to: String)]) async -> [String: Int] {
        var result: [String: Int] = [:]
        for leg in legs {
            if let mins = await commuteMinutes(from: leg.from, to: leg.to) {
                result[leg.label] = mins
            }
        }
        return result
    }
}
