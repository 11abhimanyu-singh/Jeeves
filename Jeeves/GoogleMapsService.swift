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

    /// Traffic-aware driving minutes between two addresses/place names, or nil
    /// if it can't be determined (missing key, bad address, network/API error).
    ///
    /// Pass `departure` (the leg's scheduled departure) to get Google's
    /// PREDICTED traffic for that time of day rather than traffic right now —
    /// planning tonight for a 13:30 leg tomorrow should price in midday
    /// traffic, not midnight's empty roads. A nil or past departure falls back
    /// to live "leave now" traffic (the API rejects past departure times).
    static func commuteMinutes(from origin: String, to destination: String, departure: Date? = nil) async -> Int? {
        let o = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty, !d.isEmpty,
              let apiKey = KeychainService.loadGoogleMapsAPIKey(), !apiKey.isEmpty else { return nil }

        let body = requestBody(origin: o, destination: d, departure: departure, now: Date())

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
    /// any leg it can't resolve; the planner uses its default for those. Each
    /// leg carries its scheduled departure so estimates use predicted traffic
    /// for that time of day (nil departure = live traffic now).
    static func commuteEstimates(legs: [(label: String, from: String, to: String, departure: Date?)]) async -> [String: Int] {
        var result: [String: Int] = [:]
        for leg in legs {
            if let mins = await commuteMinutes(from: leg.from, to: leg.to, departure: leg.departure) {
                result[leg.label] = mins
            }
        }
        return result
    }

    /// The computeRoutes request body. Pure (injected `now`) and unit-tested:
    /// a future departure (≥60s of slack so a "departing right now" timestamp
    /// doesn't race the server clock) upgrades to TRAFFIC_AWARE_OPTIMAL with a
    /// departureTime; a nil or past/imminent departure stays on plain
    /// TRAFFIC_AWARE live traffic, which the API prices as "leave now".
    static func requestBody(origin: String, destination: String, departure: Date?, now: Date) -> [String: Any] {
        var body: [String: Any] = [
            "origin": ["address": origin],
            "destination": ["address": destination],
            "travelMode": "DRIVE",
            "routingPreference": "TRAFFIC_AWARE",
        ]
        if let departure, departure > now.addingTimeInterval(60) {
            body["departureTime"] = rfc3339.string(from: departure)
            body["routingPreference"] = "TRAFFIC_AWARE_OPTIMAL" // predictive traffic model
        }
        return body
    }

    /// RFC 3339 / ISO 8601 UTC timestamp, the format computeRoutes expects
    /// for departureTime (e.g. "2026-07-21T08:00:00Z").
    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
