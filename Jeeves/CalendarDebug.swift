//
//  CalendarDebug.swift
//  Jeeves
//
//  Writes the raw Google Calendar API response from the last fetch into the
//  app's iCloud Drive folder, so a "day comes back empty" problem can be
//  diagnosed off-device: exactly what Google returned (items, an error, a
//  different calendar), the query window used, and whether the request even
//  fired. Temporary diagnostics — safe to remove once calendar sync is solid.
//  It only ever writes to the user's own private iCloud container.
//

import Foundation

enum CalendarDebug {
    nonisolated static func log(day: Date, url: String, status: Int, body: Data) {
        let stamp = DateFormatter()
        stamp.timeZone = TimeZone(identifier: "Asia/Kolkata")
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss 'IST'"
        let dayFmt = DateFormatter()
        dayFmt.timeZone = TimeZone(identifier: "Asia/Kolkata")
        dayFmt.dateFormat = "yyyy-MM-dd"

        let bodyStr = String(data: body.prefix(30_000), encoding: .utf8) ?? "<non-utf8 body>"
        let payload: [String: Any] = [
            "queriedDay": dayFmt.string(from: day),
            "fetchedAt": stamp.string(from: Date()),
            "httpStatus": status,
            "requestURL": url,
            "byteCount": body.count,
            "rawResponse": bodyStr,
        ]
        guard let out = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let container = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.abhimanyusingh.me.Jeeves")
        else { return }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let dest = docs.appendingPathComponent("calendar-debug.json")
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing, error: &coordinationError) { target in
            try? out.write(to: target, options: .atomic)
        }
    }
}
