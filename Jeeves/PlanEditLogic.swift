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

    // `hhmm` used to live here as a private copy. It is now on GeneratedBlock
    // beside `minutes(from:)`, its inverse — the editor already wrapped past
    // midnight while the offline packer's own formatter did not, which is how
    // "Sleep 23:00 → 31:00" reached the store on every offline plan ever made.
    // One formatter, one behaviour.

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
        // Fixed anchor intervals — movable blocks must flow around, never over, these.
        let anchors: [(start: Int, end: Int)] = blocks.compactMap { b in
            guard b.isAnchor, let s = b.startMinute, let e = b.endMinute else { return nil }
            return (s, e)
        }
        var cursor = origin
        return blocks.map { block in
            if block.isAnchor, let end = block.endMinute {
                cursor = max(cursor, end)
                return block                       // pinned — unchanged
            }
            let duration = block.durationMinutes
            // If placing here would run into a pinned anchor, jump past that
            // anchor's end first (looping for a block long enough to span
            // several), so a lengthened movable never overlaps a commitment.
            while let clash = anchors.first(where: { $0.end > cursor && cursor + duration > $0.start }) {
                cursor = max(cursor, clash.end)
            }
            let placed = block.placed(at: cursor, durationMinutes: duration)
            cursor += duration
            return placed
        }
    }
}
