//
//  JeevesChatServiceTests.swift
//  JeevesTests
//
//  Coverage for the one bug-prone pure piece of the agentic chat: resolving a
//  tool's `date` argument to the right calendar day. The tool-use loop itself
//  is I/O bound (URLSession) and is exercised by the live smoke test, not here.
//

import XCTest
@testable import Jeeves

final class JeevesChatServiceTests: XCTestCase {

    // A fixed reference "today" so the assertions don't drift with the clock.
    private let today: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 22
        return Calendar.current.date(from: c)!.startOfDay
    }()

    private func day(after n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: n, to: today)!.startOfDay
    }

    func testResolvesTodayAndNil() {
        XCTAssertEqual(JeevesChatService.resolveDate("today", relativeTo: today), today)
        XCTAssertEqual(JeevesChatService.resolveDate("Today", relativeTo: today), today)
        XCTAssertEqual(JeevesChatService.resolveDate("tonight", relativeTo: today), today)
        XCTAssertEqual(JeevesChatService.resolveDate(nil, relativeTo: today), today, "missing date → today")
        XCTAssertEqual(JeevesChatService.resolveDate("", relativeTo: today), today)
    }

    func testResolvesTomorrow() {
        XCTAssertEqual(JeevesChatService.resolveDate("tomorrow", relativeTo: today), day(after: 1))
        XCTAssertEqual(JeevesChatService.resolveDate("plan TOMORROW please", relativeTo: today), day(after: 1))
    }

    func testDayAfterTomorrowBeatsTomorrowSubstring() {
        // "day after tomorrow" contains "tomorrow" — the order of checks matters.
        XCTAssertEqual(JeevesChatService.resolveDate("day after tomorrow", relativeTo: today), day(after: 2))
    }

    func testResolvesISODate() {
        XCTAssertEqual(JeevesChatService.resolveDate("2026-07-25", relativeTo: today), day(after: 3))
        // DateFormatter is lenient about the separator, which is what we want —
        // the model may emit a slash. Resolving it to the 25th is correct.
        XCTAssertEqual(JeevesChatService.resolveDate("2026/07/25", relativeTo: today), day(after: 3))
    }

    func testUnrecognisedFallsBackToToday() {
        XCTAssertEqual(JeevesChatService.resolveDate("sometime next week", relativeTo: today), today)
        XCTAssertEqual(JeevesChatService.resolveDate("whenever", relativeTo: today), today)
    }
}
