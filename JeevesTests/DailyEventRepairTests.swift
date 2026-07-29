//
//  DailyEventRepairTests.swift
//  JeevesTests
//
//  Launch repair for corrupted event times (end before start) — the Aug 16/17
//  rows that stored 13:00→12:00 and rendered as negative-length blocks.
//

import XCTest
import SwiftData
@testable import Jeeves

@MainActor
final class DailyEventRepairTests: XCTestCase {

    // Held so the store outlives makeContext() — a ModelContext whose
    // container has deallocated crashes on first use.
    private var container: ModelContainer!

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([DailyEvent.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        return container.mainContext
    }

    func testCalendarRowRevertsToAllDay() throws {
        let context = try makeContext()
        let e = DailyEvent(date: Date(), title: "Bhadra",
                           startMinute: 780, endMinute: 720,   // 13:00 → 12:00, corrupted
                           source: .calendar)
        context.insert(e)

        DailyEvent.repairInvalidTimes(context: context)

        XCTAssertTrue(e.isAllDay, "a calendar row's minutes were never real — its true shape is all-day")
        XCTAssertEqual(e.startMinute, 0)
        XCTAssertEqual(e.endMinute, 0)
    }

    func testManualRowGetsTimesSwapped() throws {
        let context = try makeContext()
        let e = DailyEvent(date: Date(), title: "Dinner",
                           startMinute: 1200, endMinute: 1080,  // 20:00 → 18:00, backwards
                           source: .manual)
        context.insert(e)

        DailyEvent.repairInvalidTimes(context: context)

        XCTAssertFalse(e.isAllDay)
        XCTAssertEqual(e.startMinute, 1080)
        XCTAssertEqual(e.endMinute, 1200)
    }

    func testHealthyRowsUntouched() throws {
        let context = try makeContext()
        let timed = DailyEvent(date: Date(), title: "Standup", startMinute: 600, endMinute: 660)
        let allDay = DailyEvent(date: Date(), title: "Bali", startMinute: 0, endMinute: 0, isAllDay: true)
        [timed, allDay].forEach { context.insert($0) }

        DailyEvent.repairInvalidTimes(context: context)

        XCTAssertEqual(timed.startMinute, 600)
        XCTAssertEqual(timed.endMinute, 660)
        XCTAssertTrue(allDay.isAllDay)
    }
}
