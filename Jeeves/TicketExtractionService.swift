//
//  TicketExtractionService.swift
//  Jeeves
//
//  A ticket PDF becomes a list of flights.
//
//  Text first, vision second. An e-ticket almost always carries a real text
//  layer, and reading it is cheaper, faster and far more accurate than
//  screenshotting a page and asking a model to read pixels. Vision stays as
//  the fallback for scans and photos.
//
//  The model's ONLY job is transcription — pull the printed fields out of a
//  messy table. It is explicitly told not to convert timezones, not to
//  compute durations, and not to reason about connections, because every one
//  of those is checked deterministically afterwards in TicketItinerary. A
//  model that "helpfully" normalised times to UTC would break the one
//  cross-check that makes the whole feature safe.
//

import Foundation
import PDFKit
import UIKit

enum TicketExtractionError: LocalizedError {
    case missingAPIKey
    case unreadablePDF
    case noTextLayer
    case requestFailed(String)
    case unparsableResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:      return "Add your Anthropic API key in Settings first."
        case .unreadablePDF:      return "Couldn't open that PDF."
        case .noTextLayer:        return "That PDF has no readable text — it looks like a scan."
        case .requestFailed(let m): return m
        case .unparsableResponse: return "Couldn't read the flights out of that ticket."
        }
    }
}

enum TicketExtractionService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-opus-5"

    // MARK: PDF → text

    /// Plain text from a PDF, or nil when there's no text layer to read.
    /// Pure and synchronous — no network, so it's testable with a fixture.
    static func text(from data: Data) -> String? {
        guard let doc = PDFDocument(data: data) else { return nil }
        var out = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string {
                out += s + "\n"
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when the document carries enough text to be worth sending.
    static func hasUsableText(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.count >= 200
    }

    // MARK: Text → legs

    /// A PDF: read its text layer if it has one, otherwise render page 1 and
    /// look at it. A scanned or photographed ticket saved as a PDF used to
    /// dead-end here with "no readable text"; now it just takes the slower
    /// road.
    static func extract(from data: Data) async throws -> (legs: [TicketLeg], booking: TicketBooking) {
        let raw = text(from: data)
        if hasUsableText(raw), let raw {
            return try await extract(fromText: raw)
        }
        guard let image = firstPageImage(from: data) else {
            throw TicketExtractionError.unreadablePDF
        }
        return try await extract(fromImage: image)
    }

    /// A photo or screenshot of a ticket.
    static func extract(fromImage image: UIImage) async throws -> (legs: [TicketLeg], booking: TicketBooking) {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw TicketExtractionError.missingAPIKey
        }
        guard let jpeg = downscaled(image).jpegData(compressionQuality: 0.7) else {
            throw TicketExtractionError.unreadablePDF
        }
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": [[
                "type": "text",
                "text": systemPrompt,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg",
                                "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": "Transcribe every flight on this ticket."],
                ],
            ]],
        ]
        return try await send(payload, apiKey: apiKey)
    }

    /// Renders the first page of a PDF at a legible size for vision.
    static func firstPageImage(from data: Data) -> UIImage? {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // 2x so small print survives; the downscale below caps the long edge.
        let scale: CGFloat = 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }

    /// Caps the long edge so a 12-megapixel photo doesn't become a huge
    /// base64 payload for no extra legibility.
    static func downscaled(_ image: UIImage, maxEdge: CGFloat = 1800) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let ratio = maxEdge / longest
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func extract(fromText raw: String) async throws -> (legs: [TicketLeg], booking: TicketBooking) {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw TicketExtractionError.missingAPIKey
        }
        // Tickets repeat boilerplate; the flights are near the top. Trimming
        // keeps the prompt cheap without losing the itinerary.
        let body = String(raw.prefix(14_000))

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": [[
                "type": "text",
                "text": systemPrompt,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": [["role": "user", "content": body]],
        ]
        return try await send(payload, apiKey: apiKey)
    }

    /// One request path for both text and image, so the parsing contract and
    /// the error handling can't drift apart between them.
    private static func send(_ payload: [String: Any],
                             apiKey: String) async throws -> (legs: [TicketLeg], booking: TicketBooking) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TicketExtractionError.requestFailed("No response from server.")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw TicketExtractionError.requestFailed("HTTP \(http.statusCode)" + (message.map { ": \($0)" } ?? ""))
        }
        guard let text = PlanGenerationService.extractText(from: responseData) else {
            throw TicketExtractionError.unparsableResponse
        }
        guard let parsed = decode(text) else {
            throw TicketExtractionError.unparsableResponse
        }
        return parsed
    }

    // MARK: Decoding — pure, so the contract is testable without network

    private struct Wire: Decodable {
        struct Leg: Decodable {
            let flightNumber: String
            let carrier: String?
            let from: String
            let to: String
            let departDate: String     // yyyy-MM-dd, local to `from`
            let departTime: String     // HH:mm, 24h
            let arriveDate: String
            let arriveTime: String
            let durationMinutes: Int?
            let fromTerminal: String?
            let toTerminal: String?
        }
        let legs: [Leg]
        let bookingReference: String?
        let airlineReference: String?
        let passengers: [String]?
        let bookedByName: String?
        let bookedByPhone: String?
    }

    /// The outermost {...} in a reply, so a stray sentence or a ```json fence
    /// doesn't defeat the parse. Local rather than borrowed from
    /// PlanGenerationService so this file owns its own contract.
    static func outermostJSONObject(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{") else { return text }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if escaped { escaped = false }
            else if ch == "\\" && inString { escaped = true }
            else if ch == "\"" { inString.toggle() }
            else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return String(text[start...])
    }

    /// Parses the model's JSON into the app's own types.
    static func decode(_ text: String) -> (legs: [TicketLeg], booking: TicketBooking)? {
        let json = outermostJSONObject(text)
        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              !wire.legs.isEmpty else { return nil }

        let legs: [TicketLeg] = wire.legs.compactMap { l in
            guard let dep = components(date: l.departDate, time: l.departTime),
                  let arr = components(date: l.arriveDate, time: l.arriveTime) else { return nil }
            return TicketLeg(flightNumber: l.flightNumber.trimmingCharacters(in: .whitespaces),
                             carrier: l.carrier ?? "",
                             from: l.from.trimmingCharacters(in: .whitespaces).uppercased(),
                             to: l.to.trimmingCharacters(in: .whitespaces).uppercased(),
                             departLocal: dep, arriveLocal: arr,
                             printedMinutes: l.durationMinutes,
                             fromTerminal: l.fromTerminal?.nilIfBlank,
                             toTerminal: l.toTerminal?.nilIfBlank)
        }
        guard legs.count == wire.legs.count else { return nil }

        let booking = TicketBooking(reference: wire.bookingReference?.nilIfBlank,
                                    airlineReference: wire.airlineReference?.nilIfBlank,
                                    passengerNames: wire.passengers ?? [],
                                    bookedByName: wire.bookedByName?.nilIfBlank,
                                    bookedByPhone: wire.bookedByPhone?.nilIfBlank)
        return (legs, booking)
    }

    /// "2026-09-03" + "23:05" → date components, with no timezone attached.
    /// The zone comes from the airport later; putting one on here would be
    /// guessing at the very thing the cross-check exists to verify.
    static func components(date: String, time: String) -> DateComponents? {
        let d = date.split(separator: "-").compactMap { Int($0) }
        let t = time.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count >= 2,
              (1...12).contains(d[1]), (1...31).contains(d[2]),
              (0...23).contains(t[0]), (0...59).contains(t[1]) else { return nil }
        return DateComponents(year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1])
    }

    private static let systemPrompt = """
    You transcribe airline e-tickets. You are a careful reader, not an \
    interpreter.

    Return ONLY a JSON object, no prose and no markdown fences:
    {
      "legs": [
        {
          "flightNumber": "SQ 511",
          "carrier": "Singapore Airlines",
          "from": "BLR",
          "to": "SIN",
          "departDate": "2026-09-03",
          "departTime": "23:05",
          "arriveDate": "2026-09-04",
          "arriveTime": "06:10",
          "durationMinutes": 275,
          "fromTerminal": null,
          "toTerminal": null
        }
      ],
      "bookingReference": "AO261868215",
      "airlineReference": "DOULTU",
      "passengers": ["MR. ABHIMANYU SINGH"],
      "bookedByName": "Joy Holidays",
      "bookedByPhone": "8989225239"
    }

    RULES — these matter more than being helpful:
    - Copy times EXACTLY as printed. Every time on a ticket is local to its \
      own airport. Do NOT convert anything to UTC or to a single timezone. \
      Do NOT adjust a time because it looks wrong.
    - durationMinutes is the duration the TICKET states, converted to minutes \
      ("04 hrs 35 mins" → 275). If no duration is printed, use null. Never \
      calculate it yourself — it is used to check the times, so a computed \
      value would check nothing.
    - from/to are 3-letter IATA codes. If a code is not printed, infer it from \
      the airport name only when you are certain; otherwise use the name.
    - Terminals are usually absent. Use null rather than guessing.
    - passengers: the travellers. bookedByName / bookedByPhone: the TRAVEL \
      AGENT or issuer, which on many tickets is the only contact shown. Keep \
      them separate — an agency's phone number is not the traveller's.
    - List legs in the order printed, including every leg of a return trip.
    - A "layover" line is not a leg. Ignore it; it is derived from the gap.
    """
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
