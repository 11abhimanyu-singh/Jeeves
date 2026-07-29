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
//  Routes geocodes plain addresses and place names itself, but it can't read a
//  Google Maps SHORT LINK (maps.app.goo.gl/…) — the form you get from the
//  Maps "share" button and often paste into an event. So before routing we
//  resolve such links to coordinates by following the redirect and pulling the
//  lat/lng out of the expanded URL. Without this, a shared-link destination
//  silently falls back to the default commute minutes.
//

import Foundation

enum GoogleMapsService {
    private static let endpoint = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!

    /// A routing endpoint — either a free-text address/place (Routes geocodes
    /// it) or explicit coordinates (used once we've resolved a Maps link).
    enum Waypoint: Equatable {
        case address(String)
        case location(lat: Double, lng: Double)

        var requestJSON: [String: Any] {
            switch self {
            case .address(let a): return ["address": a]
            case .location(let lat, let lng): return ["location": ["latLng": ["latitude": lat, "longitude": lng]]]
            }
        }
    }

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

        // Resolve any Maps short link to coordinates before routing; plain
        // addresses pass straight through for Routes to geocode.
        let originWaypoint = await resolveWaypoint(o)
        let destinationWaypoint = await resolveWaypoint(d)
        let body = requestBody(origin: originWaypoint, destination: destinationWaypoint, departure: departure, now: Date())

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("routes.duration", forHTTPHeaderField: "X-Goog-FieldMask")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return parseMinutes(data)
        } catch {
            return nil
        }
    }

    /// Pure decode + map of the Routes API (computeRoutes) response into rounded
    /// driving minutes. Extracted from the network call so it can be unit-tested
    /// against real payloads with no key and no round-trip. Reads the first
    /// route's `duration` — a protobuf-style seconds string like "2491s" (which
    /// can carry a fractional part, e.g. "150.5s") — and rounds to whole minutes.
    /// Returns nil, not a throw, on empty routes, a missing/malformed duration,
    /// an API error body, or junk — so a failed route falls back to the user's
    /// default commute minutes.
    static func parseMinutes(_ data: Data) -> Int? {
        struct Response: Decodable {
            struct Route: Decodable { let duration: String? } // e.g. "2491s"
            let routes: [Route]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let durationString = decoded.routes.first?.duration,
              let seconds = Double(durationString.replacingOccurrences(of: "s", with: "")) else { return nil }
        return Int((seconds / 60).rounded())
    }

    /// Resolves the commute legs a plan needs, keyed "From→To" to match the
    /// prompt's expected format (PlanRequest.commuteEstimates). Silently omits
    /// any leg it can't resolve; the planner uses its default for those. Each
    /// leg carries its scheduled departure so estimates use predicted traffic
    /// for that time of day (nil departure = live traffic now).
    static func commuteEstimates(legs: [(label: String, from: String, to: String, departure: Date?)]) async -> [String: Int] {
        // Fetch every leg concurrently — they're independent network calls, so
        // running them in parallel turns N sequential round-trips into one.
        await withTaskGroup(of: (String, Int?).self) { group in
            for leg in legs {
                group.addTask { (leg.label, await commuteMinutes(from: leg.from, to: leg.to, departure: leg.departure)) }
            }
            var result: [String: Int] = [:]
            for await (label, mins) in group where mins != nil {
                result[label] = mins
            }
            return result
        }
    }

    /// The computeRoutes request body. Pure (injected `now`) and unit-tested:
    /// a future departure (≥60s of slack so a "departing right now" timestamp
    /// doesn't race the server clock) upgrades to TRAFFIC_AWARE_OPTIMAL with a
    /// departureTime; a nil or past/imminent departure stays on plain
    /// TRAFFIC_AWARE live traffic, which the API prices as "leave now".
    static func requestBody(origin: Waypoint, destination: Waypoint, departure: Date?, now: Date) -> [String: Any] {
        var body: [String: Any] = [
            "origin": origin.requestJSON,
            "destination": destination.requestJSON,
            "travelMode": "DRIVE",
            "routingPreference": "TRAFFIC_AWARE",
        ]
        if let departure, departure > now.addingTimeInterval(60) {
            body["departureTime"] = rfc3339.string(from: departure)
            body["routingPreference"] = "TRAFFIC_AWARE_OPTIMAL" // predictive traffic model
        }
        return body
    }

    // MARK: Maps-link resolution

    /// Turns a destination string into a routing waypoint. A Google Maps short
    /// link is expanded to coordinates; anything else is passed through as an
    /// address for Routes to geocode (including a link we couldn't resolve, so
    /// there's no regression versus before).
    static func resolveWaypoint(_ raw: String) async -> Waypoint {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMapsLink(s) else { return .address(s) }
        // A long maps URL often already embeds the coordinates — try that first,
        // no network needed.
        if let c = extractCoordinates(fromText: s) { return .location(lat: c.lat, lng: c.lng) }
        // Otherwise follow the (short) link and scan the final URL + page body.
        if let text = await expand(s), let c = extractCoordinates(fromText: text) {
            return .location(lat: c.lat, lng: c.lng)
        }
        return .address(s)
    }

    /// A place identified from a Maps link: a human-readable name, the full
    /// street address (reverse-geocoded from the pin, when possible), and the
    /// exact pin coordinates when the URL exposes them.
    nonisolated struct ResolvedPlace: Equatable, Sendable {
        var name: String
        var address: String?
        var lat: Double?
        var lng: Double?
        /// The best string to store/route with: full address if we have it, else
        /// the place name.
        var displayAddress: String { address ?? name }
    }

    /// Identifies a Google Maps link as a place — e.g. a pasted
    /// `https://maps.app.goo.gl/…` becomes "BlueStone Jewellery Koramangala" with
    /// a full street address and pin. Expands a short link if needed, reads the
    /// name from `/maps/place/<NAME>/` and the pin from `!3d…!4d…`, then
    /// reverse-geocodes the pin to a full address. Returns nil for non-links or
    /// anything it can't resolve (the caller keeps the raw text — no regression).
    static func resolvePlace(_ raw: String) async -> ResolvedPlace? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMapsLink(s) else { return nil }
        // Parse the URL directly first; expand a short link only if we still lack
        // the name or the pin.
        var name = placeName(fromText: s)
        var coord = extractCoordinates(fromText: s)
        if name == nil || coord == nil, let text = await expand(s) {
            name = name ?? placeName(fromText: text)
            coord = coord ?? extractCoordinates(fromText: text)
        }
        guard name != nil || coord != nil else { return nil }
        var address: String? = nil
        if let c = coord { address = await reverseGeocode(lat: c.lat, lng: c.lng) }
        return ResolvedPlace(name: name ?? "Pinned location", address: address,
                             lat: coord?.lat, lng: coord?.lng)
    }

    /// Forward-geocode a TYPED or SPOKEN place ("JLR River Tern Lodge") into a
    /// real pin. Until this existed only pasted Maps links resolved, so a venue
    /// the user typed had no coordinates and no journey could be measured to it
    /// — which is how a 265 km drive once got planned as a 30-minute commute.
    /// Uses the Geocoding API's free-text search; nil when nothing matches, so
    /// callers can say "I couldn't find that" instead of inventing a distance.
    static func geocodePlace(_ raw: String) async -> ResolvedPlace? {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isMapsLink(query),
              let key = KeychainService.loadGoogleMapsAPIKey(), !key.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://maps.googleapis.com/maps/api/geocode/json?address=\(encoded)&key=\(key)")
        else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return parseGeocode(data, fallbackName: query)
    }

    /// Pure decode of a Geocoding response — extracted so the parse is testable
    /// without a key or a round-trip.
    nonisolated static func parseGeocode(_ data: Data, fallbackName: String) -> ResolvedPlace? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["status"] as? String) == "OK",
              let results = json["results"] as? [[String: Any]],
              let first = results.first else { return nil }
        let address = first["formatted_address"] as? String
        let loc = (first["geometry"] as? [String: Any])?["location"] as? [String: Any]
        return ResolvedPlace(name: fallbackName, address: address,
                             lat: loc?["lat"] as? Double, lng: loc?["lng"] as? Double)
    }

    /// Reverse-geocodes a pin to a full formatted street address via the
    /// Geocoding API. Nil if there's no key, no network, or no result — callers
    /// fall back to the place name.
    static func reverseGeocode(lat: Double, lng: Double) async -> String? {
        guard let key = KeychainService.loadGoogleMapsAPIKey(), !key.isEmpty,
              let url = URL(string: "https://maps.googleapis.com/maps/api/geocode/json?latlng=\(lat),\(lng)&key=\(key)")
        else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        struct GeoResponse: Decodable {
            struct Result: Decodable { let formatted_address: String }
            let results: [Result]
        }
        return (try? JSONDecoder().decode(GeoResponse.self, from: data))?.results.first?.formatted_address
    }

    /// Pulls the place name from a Maps URL's `/maps/place/<NAME>/` segment,
    /// turning "BlueStone+Jewellery+Koramangala" into "BlueStone Jewellery
    /// Koramangala". Pure — nil when the URL has no place segment.
    static func placeName(fromText text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"/maps/place/([^/@?]+)"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let spaced = String(text[r]).replacingOccurrences(of: "+", with: " ")
        let name = (spaced.removingPercentEncoding ?? spaced)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// True for a Google Maps URL (short share link or a maps.google.com URL).
    /// Plain addresses / place names are NOT links and route straight through.
    static func isMapsLink(_ s: String) -> Bool {
        guard s.lowercased().hasPrefix("http"), let url = URL(string: s),
              let host = url.host?.lowercased() else { return false }
        if host == "maps.app.goo.gl" || host == "goo.gl" || host == "maps.google.com" { return true }
        return host.contains("google.") && url.path.lowercased().contains("maps")
    }

    /// Pulls a lat,lng out of a Maps URL (or a page's HTML), most-reliable form
    /// first: the `!3d<lat>!4d<lng>` place-data param (the actual pin), then
    /// explicit query params, then the `@lat,lng` viewport centre as a last
    /// resort. Pure — unit-tested against real URL shapes. Coordinates outside
    /// valid earth ranges are rejected.
    static func extractCoordinates(fromText text: String) -> (lat: Double, lng: Double)? {
        let patterns = [
            #"!3d(-?\d{1,3}\.\d+)!4d(-?\d{1,3}\.\d+)"#,
            #"[?&](?:q|query|ll|destination|center|sll|daddr)=(-?\d{1,3}\.\d+),\s*(-?\d{1,3}\.\d+)"#,
            #"@(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)"#,
        ]
        for pattern in patterns {
            if let c = firstCoordinate(pattern, in: text) { return c }
        }
        return nil
    }

    private static func firstCoordinate(_ pattern: String, in text: String) -> (lat: Double, lng: Double)? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 3,
              let latRange = Range(m.range(at: 1), in: text),
              let lngRange = Range(m.range(at: 2), in: text),
              let lat = Double(text[latRange]), let lng = Double(text[lngRange]),
              (-90...90).contains(lat), (-180...180).contains(lng) else { return nil }
        return (lat, lng)
    }

    /// Follows a short link's redirects and returns the final URL plus a slice
    /// of the page body, so coordinates in either can be extracted. Best-effort.
    private static func expand(_ link: String) async -> String? {
        guard let url = URL(string: link) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        // Some link shorteners serve a bare redirect only to a browser UA.
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        let finalURL = response.url?.absoluteString ?? ""
        let body = String(data: data.prefix(40_000), encoding: .utf8) ?? ""
        return finalURL + " " + body
    }

    /// RFC 3339 / ISO 8601 UTC timestamp, the format computeRoutes expects
    /// for departureTime (e.g. "2026-07-21T08:00:00Z").
    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
