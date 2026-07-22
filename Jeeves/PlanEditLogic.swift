//
//  PlanEditLogic.swift
//  Jeeves
//
//  Lets the user tweak a generated plan by hand — reorder the movable blocks
//  and change their lengths — while the fixed commitments stay put. Anchors
//  (gym, events, sleep, the peak-focus reading) keep their clock times; every
//  other block flows contiguously around them. Pure and unit-tested; the editor
//  UI just drives it.
//

import Foundation

extension GeneratedBlock {
    var durationMinutes: Int { max(0, (endMinute ?? 0) - (startMinute ?? 0)) }

    private static func hhmm(_ m: Int) -> String {
        String(format: "%02d:%02d", (m / 60) % 24, m % 60)
    }

    /// A copy placed at `startMinute` for `durationMinutes`.
    func placed(at startMinute: Int, durationMinutes: Int) -> GeneratedBlock {
        GeneratedBlock(title: title,
                       startTime: Self.hhmm(startMinute),
                       endTime: Self.hhmm(startMinute + durationMinutes),
                       note: note, isAnchor: isAnchor, kind: kind)
    }

    /// A copy with a new length, keeping its start.
    func withDuration(_ minutes: Int) -> GeneratedBlock {
        placed(at: startMinute ?? 0, durationMinutes: minutes)
    }

    /// A copy with an edited title, note/location, and length (start unchanged;
    /// re-timing fixes the clock).
    func edited(title: String, note: String?, durationMinutes: Int) -> GeneratedBlock {
        let start = startMinute ?? 0
        let cleaned = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GeneratedBlock(title: title,
                              startTime: Self.hhmm(start),
                              endTime: Self.hhmm(start + durationMinutes),
                              note: (cleaned?.isEmpty ?? true) ? nil : cleaned,
                              isAnchor: isAnchor, kind: kind)
    }
}

enum PlanEditLogic {
    /// Re-time a reordered / duration-edited block list. Anchors keep their
    /// fixed clock times (pinned); movable blocks flow contiguously from the
    /// first block's start, and the cursor jumps to each anchor's end so
    /// subsequent movable blocks continue after it.
    static func retime(_ blocks: [GeneratedBlock]) -> [GeneratedBlock] {
        // Anchor the cascade to the day's earliest start, not the first block's
        // — after a reorder the first block's own time is meaningless.
        guard let origin = blocks.compactMap(\.startMinute).min() else { return blocks }
        var cursor = origin
        return blocks.map { block in
            if block.isAnchor, let end = block.endMinute {
                cursor = max(cursor, end)
                return block                       // pinned — unchanged
            }
            let placed = block.placed(at: cursor, durationMinutes: block.durationMinutes)
            cursor += block.durationMinutes
            return placed
        }
    }
}
