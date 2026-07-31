//
//  CalendarTombstone.swift
//  Jeeves
//
//  A deletion the user made must STAY deleted. Calendar sync is idempotent
//  for existing events (externalID upsert), but a locally deleted event had
//  no record of ever existing — the next sync of that day quietly
//  resurrected it (the Bhadra Tiger Reserve rows came back after chat
//  reported them deleted). A tombstone remembers the externalID of every
//  deleted synced event; sync skips tombstoned IDs instead of re-importing.
//

import Foundation
import SwiftData

@Model
final class CalendarTombstone {
    var externalID: String = ""
    var deletedAt: Date = Date()

    init(externalID: String = "", deletedAt: Date = Date()) {
        self.externalID = externalID
        self.deletedAt = deletedAt
    }

    /// The set of tombstoned calendar IDs — what sync must never re-import.
    static func ids(in context: ModelContext) -> Set<String> {
        let rows = (try? context.fetch(FetchDescriptor<CalendarTombstone>())) ?? []
        return Set(rows.map(\.externalID).filter { !$0.isEmpty })
    }
}
