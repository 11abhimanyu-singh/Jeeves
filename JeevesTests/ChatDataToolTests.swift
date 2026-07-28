//
//  ChatDataToolTests.swift
//  JeevesTests
//
//  Pure logic behind the chat's new capabilities: add_reminder's fire-date
//  resolution (past times roll forward), the Couch-to-5K programme serializer
//  fetch_app_data serves, and the voice-note retention window.
//

import XCTest
@testable import Jeeves

final class ChatDataToolTests: XCTestCase {

    private var cal: Calendar { Calendar.current }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: add_reminder fire-date

    func testFutureTimeTodayStaysToday() {
        let now = at(2026, 7, 29, 10)
        let fire = JeevesChatService.resolveFireDate(dateRaw: "today", timeRaw: "18:00", relativeTo: now)
        XCTAssertEqual(fire, at(2026, 7, 29, 18))
    }

    func testPastTimeRollsToTomorrow() {
        // "Remind me at 9am" typed at 11pm means tomorrow morning, not a
        // reminder that never fires.
        let now = at(2026, 7, 29, 23)
        let fire = JeevesChatService.resolveFireDate(dateRaw: nil, timeRaw: "09:00", relativeTo: now)
        XCTAssertEqual(fire, at(2026, 7, 30, 9))
    }

    func testExplicitDateAndTime() {
        let now = at(2026, 7, 29, 10)
        let fire = JeevesChatService.resolveFireDate(dateRaw: "2026-08-02", timeRaw: "07:30", relativeTo: now)
        XCTAssertEqual(fire, at(2026, 8, 2, 7, 30))
    }

    func testTomorrowKeyword() {
        let now = at(2026, 7, 29, 10)
        let fire = JeevesChatService.resolveFireDate(dateRaw: "tomorrow", timeRaw: "06:00", relativeTo: now)
        XCTAssertEqual(fire, at(2026, 7, 30, 6))
    }

    func testMalformedTimeDefaultsSanely() {
        let now = at(2026, 7, 29, 10)
        let fire = JeevesChatService.resolveFireDate(dateRaw: "today", timeRaw: "later", relativeTo: now)
        // Unparseable time → 09:00; already past 9am → rolls to tomorrow 9am.
        XCTAssertEqual(fire, at(2026, 7, 30, 9))
    }

    // MARK: run_program serializer (fetch_app_data)

    func testRunProgramSummaryServesAllWeeks() throws {
        let json = JeevesChatService.runProgramSummary()
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let weeks = try XCTUnwrap(obj["weeks"] as? [[String: Any]])
        XCTAssertEqual(weeks.count, RunProgram.weeks.count)
        XCTAssertEqual(obj["count"] as? Int, RunProgram.weeks.count)
        // Every week carries the continuous-run metric the user asks about.
        for w in weeks {
            XCTAssertNotNil(w["longestUnbrokenRunMinutes"] as? Int)
            XCTAssertNotNil(w["week"] as? Int)
            XCTAssertNotNil(w["focus"] as? String)
        }
        // The programme progresses: some later week runs longer unbroken than week 1.
        let firstLongest = weeks.first?["longestUnbrokenRunMinutes"] as? Int ?? 0
        let maxLongest = weeks.compactMap { $0["longestUnbrokenRunMinutes"] as? Int }.max() ?? 0
        XCTAssertGreaterThan(maxLongest, firstLongest)
    }

    // MARK: fuzzy matching (edit/delete/complete tools)

    func testFuzzyMatchPartialTitle() {
        XCTAssertTrue(JeevesChatService.fuzzyMatch("Bhadra Tiger Reserve -Tour", query: "bhadra"))
        XCTAssertTrue(JeevesChatService.fuzzyMatch("Buy protein powder", query: "protein"))
        XCTAssertTrue(JeevesChatService.fuzzyMatch("gym", query: "Gym \u{00B7} weightlifting"),
                      "short block names match longer user phrasing too")
        XCTAssertFalse(JeevesChatService.fuzzyMatch("Front Squat", query: "deadlift"))
        XCTAssertFalse(JeevesChatService.fuzzyMatch("anything", query: "   "),
                       "blank queries match nothing")
    }

    // MARK: standing-preference expiry ("for the next 45 days")

    func testUnboundedPreferenceIsAlwaysActive() {
        XCTAssertTrue(StandingPrefs.isActive("Gym is always at 7 PM", now: at(2030, 1, 1, 0)))
    }

    func testBoundedPreferenceActiveThroughExpiryDay() {
        let note = "Gym is always at 7 PM (until 2026-09-12)"
        XCTAssertTrue(StandingPrefs.isActive(note, now: at(2026, 9, 12, 23)),
                      "active through the whole expiry day")
        XCTAssertFalse(StandingPrefs.isActive(note, now: at(2026, 9, 13, 0)),
                       "lapses the day after")
    }

    func testMalformedExpiryTreatedAsPermanent() {
        XCTAssertTrue(StandingPrefs.isActive("No calls (until someday)", now: at(2030, 1, 1, 0)))
    }

    // MARK: voice-note retention

    func testPruneCutoffIs30DaysBack() {
        let now = at(2026, 7, 29, 12)
        let cutoff = VoiceNoteSync.pruneCutoff(now: now)
        XCTAssertEqual(cutoff, at(2026, 6, 29, 12))
    }
}
