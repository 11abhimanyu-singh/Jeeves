//
//  GoogleMapsService.swift
//  Jeeves
//
//  Real driving commute times with live traffic (PRD §5.4, §6) via the
//  Google Maps Distance Matrix API. Requires a user-supplied, Keychain-
//  stored Maps key. Everything here is best-effort: no key, no network, or
//  an un-geocodable address returns nil, and the planner falls back to the
//  user's default commute minutes rather than failing.
//

import Foundation

enum GoogleMapsService {
    /// Live-traffic driving minutes between two addresses, or nil if it can't
    /// be determined (missing key, bad address, network/API error).
    static func commuteMinutes(from origin: String, to destination: String) async -> Int? {
        let o = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty, !d.isEmpty,
              let apiKey = KeychainService.loadGoogleMapsAPIKey(), !apiKey.isEmpty else { return nil }

        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/distancematrix/json")
        components?.queryItems = [
            URLQueryItem(name: "origins", value: o),
            URLQueryItem(name: "destinations", value: d),
            URLQueryItem(name: "mode", value: "driving"),
            URLQueryItem(name: "departure_time", value: "now"),   // enables duration_in_traffic
            URLQueryItem(name: "key", value: apiKey),
        ]
        guard let url = components?.url else { return nil }

        struct Response: Decodable {
            struct Row: Decodable {
                struct Element: Decodable {
                    struct Duration: Decodable { let value: Int } // seconds
                    let status: String
                    let duration: Duration?
                    let durationInTraffic: Duration?
                    enum CodingKeys: String, CodingKey {
                        case status, duration
                        case durationInTraffic = "duration_in_traffic"
                    }
                }
                let elements: [Element]
            }
            let status: String
            let rows: [Row]
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard decoded.status == "OK",
                  let element = decoded.rows.first?.elements.first,
                  element.status == "OK" else { return nil }
            // Prefer traffic-aware duration; fall back to free-flow duration.
            let seconds = element.durationInTraffic?.value ?? element.duration?.value
            guard let seconds else { return nil }
            return Int((Double(seconds) / 60.0).rounded())
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
