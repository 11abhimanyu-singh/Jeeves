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

    // MARK: The no-tool-no-change detector
    //
    // A prompt rule alone let "Back to 2 nights — Radisson now ends Aug 13"
    // ship with no tool call behind it. This is the structural half: it decides
    // whether a reply ASSERTS a change, so the loop can challenge it.

    func testClaimsDetectedForCompletedActions() {
        let claims = [
            "Done — removed the Bhadra Tiger Reserve Tour on Aug 15, 16 and 17.",
            "Back to 2 nights — Radisson Mysore now ends Aug 13 again, same as before.",
            "Extended — tomorrow's dinner now runs 8–10 PM.",
            "Deleted the Western Valley stay.",
            "That pushed your Wayanad check-in to Aug 14.",
            "All set for the Colombo trip.",
        ]
        for text in claims {
            XCTAssertTrue(JeevesChatService.claimsCompletedAction(text),
                          "should read as a completed-action claim: \(text)")
        }
    }

    func testQuestionsOffersAndRefusalsAreNotClaims() {
        let notClaims = [
            "Want me to add the return drive as well?",
            "I'll add that once you tell me the checkout date.",
            "I couldn't add the stay — which trip is it part of?",
            "Which date is the drive home on?",
            "Shall I delete the Radisson stay?",
            "That would move your check-in to Aug 14 — should I?",
            "Your longest walk this month was 6.2 km.",
            "You have two events tomorrow.",
            // Retractions — what the challenge below ASKS the model to say.
            // Reading these as claims would fail a run for behaving correctly.
            "You're right — nothing was updated.",
            "Nothing was added.",
            "That change was not saved.",
            "Apologies — nothing was actually saved.",
            "The Radisson stay still ends Aug 14 — it has not been shortened.",
            "No, that hasn't been done yet.",
            "The stay still needs to be updated.",
            "Stays aren't extended in hours, only by date.",
        ]
        for text in notClaims {
            XCTAssertFalse(JeevesChatService.claimsCompletedAction(text),
                           "should NOT read as a claim: \(text)")
        }
    }

    func testClaimDetectionIsPerSentence() {
        // A genuine claim buried after an offer still counts.
        XCTAssertTrue(JeevesChatService.claimsCompletedAction(
            "Want me to add the drive home? I already deleted the old Wayanad stay."))
        // And an offer following honest inaction does not.
        XCTAssertFalse(JeevesChatService.claimsCompletedAction(
            "I haven't changed anything yet. Shall I go ahead?"))
        // The full retract-then-offer shape the challenge asks for.
        XCTAssertFalse(JeevesChatService.claimsCompletedAction(
            "You're right — nothing was updated. Want me to shorten the Radisson stay now?"))
    }

    private var cal: Calendar { Calendar.current }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: delete_event range matching ("delete everything from Sept 1 onwards")

    private func event(_ title: String, _ y: Int, _ m: Int, _ d: Int,
                       spanEnd: (Int, Int, Int)? = nil) -> DailyEvent {
        DailyEvent(date: at(y, m, d, 0), title: title, startMinute: 0, endMinute: 0,
                   isAllDay: true,
                   spanEndDate: spanEnd.map { at($0.0, $0.1, $0.2, 0) })
    }

    @MainActor
    func testRangeMatchesEverythingTouchingIt() {
        let events = [
            event("Bali", 2026, 9, 3, spanEnd: (2026, 9, 13)),
            event("Travel to Singapore", 2026, 9, 11, spanEnd: (2026, 9, 14)),
            event("Dentist", 2026, 8, 20),
            event("Diwali", 2026, 11, 8),
        ]
        let hits = JeevesChatService.eventsInRange(events, start: at(2026, 9, 1, 0),
                                                   end: at(2027, 12, 31, 0), title: nil)
        XCTAssertEqual(hits.map(\.title), ["Bali", "Travel to Singapore", "Diwali"],
                       "September 1 onwards takes everything from there, sorted")
    }

    @MainActor
    func testSpanStraddlingTheRangeStartStillMatches() {
        // An event STARTING Aug 30 but spanning into September is in
        // "September onwards" — the span touches the range.
        let events = [event("Long stay", 2026, 8, 30, spanEnd: (2026, 9, 2))]
        let hits = JeevesChatService.eventsInRange(events, start: at(2026, 9, 1, 0),
                                                   end: at(2026, 9, 30, 0), title: nil)
        XCTAssertEqual(hits.count, 1)
    }

    @MainActor
    func testTitleNarrowsTheRange() {
        let events = [
            event("Bali", 2026, 9, 3, spanEnd: (2026, 9, 13)),
            event("Travel to Singapore", 2026, 9, 11, spanEnd: (2026, 9, 14)),
        ]
        let hits = JeevesChatService.eventsInRange(events, start: at(2026, 9, 1, 0),
                                                   end: at(2026, 9, 30, 0), title: "Singapore")
        XCTAssertEqual(hits.map(\.title), ["Travel to Singapore"])
    }

    @MainActor
    func testSingleDayRangeIsExactlyThatDay() {
        let events = [event("A", 2026, 9, 3), event("B", 2026, 9, 4)]
        let hits = JeevesChatService.eventsInRange(events, start: at(2026, 9, 3, 0),
                                                   end: at(2026, 9, 3, 0), title: nil)
        XCTAssertEqual(hits.map(\.title), ["A"])
    }

    // MARK: stay matching by hotel name ("extend the Radisson by a day")

    @MainActor
    func testStaysMatchByHotelNameOrAddress() {
        let stays = [
            TripStay(tripID: UUID(), place: "Radisson Blu Mysore", address: "MG Road, Mysore",
                     arriveDate: at(2026, 8, 10, 0), departDate: at(2026, 8, 12, 0)),
            TripStay(tripID: UUID(), place: "CGH Earth Wayanad", address: "Lakkidi, Wayanad",
                     arriveDate: at(2026, 8, 12, 0), departDate: at(2026, 8, 14, 0)),
        ]
        XCTAssertEqual(JeevesChatService.staysMatching(stays, query: "Radisson").map(\.place),
                       ["Radisson Blu Mysore"])
        XCTAssertEqual(JeevesChatService.staysMatching(stays, query: "Wayanad").map(\.place),
                       ["CGH Earth Wayanad"], "address matches too")
        XCTAssertTrue(JeevesChatService.staysMatching(stays, query: "Taj").isEmpty)
    }

    @MainActor
    func testStayMatchesSortDeterministically() {
        let a = TripStay(tripID: UUID(), place: "Radisson A", address: "",
                         arriveDate: at(2026, 9, 1, 0), departDate: at(2026, 9, 2, 0))
        let b = TripStay(tripID: UUID(), place: "Radisson B", address: "",
                         arriveDate: at(2026, 8, 1, 0), departDate: at(2026, 8, 2, 0))
        let hits = JeevesChatService.staysMatching([a, b], query: "Radisson")
        XCTAssertEqual(hits.map(\.place), ["Radisson B", "Radisson A"], "earliest arrival first")
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

    // MARK: destructive matching (overnight review, HIGH)

    func testStrictMatchIsOneDirectional() {
        XCTAssertTrue(JeevesChatService.strictMatch("Dinner with Sam", query: "dinner"))
        XCTAssertFalse(JeevesChatService.strictMatch("Dinner", query: "Dinner with Sam"),
                       "a specific query must not match a shorter unrelated title")
    }

    func testBestMatchesKeepsOnlyTheClosestTitle() {
        let events = ["Dinner", "Dinner with Sam"]
        // Deleting "Dinner with Sam" must not sweep up the separate "Dinner".
        let specific = JeevesChatService.bestMatches(events, title: { $0 }, query: "Dinner with Sam")
        XCTAssertEqual(specific, ["Dinner with Sam"])
        // An exact title wins over longer ones that also contain it.
        let exact = JeevesChatService.bestMatches(events, title: { $0 }, query: "Dinner")
        XCTAssertEqual(exact, ["Dinner"])
    }

    func testBestMatchesKeepsMultiDayGroupsTogether() {
        // The same event on three days is a legitimate group edit.
        let events = ["Bhadra Tour", "Bhadra Tour", "Bhadra Tour"]
        XCTAssertEqual(JeevesChatService.bestMatches(events, title: { $0 }, query: "bhadra").count, 3)
    }

    // MARK: cardio merge (overnight review, MEDIUM)

    func testManualRunSurvivesALoggedWalk() throws {
        // An untracked run recorded in the check-in must not vanish when a walk
        // is logged the same day.
        let auto = CheckInAutoFill.derive([CheckInAutoFill.WorkoutFact(type: .walk, durationMin: 15)])
        let manual = CheckInAutoFill.ManualFacts(workedOut: true, cardio: true,
                                                 cardioType: "Running", cardioDuration: 45)
        let s = try XCTUnwrap(CheckInAutoFill.mergedDay(auto: auto, manual: manual))
        XCTAssertTrue(s.summary.contains("45min"), "the manual run is still reported: \(s.summary)")
        XCTAssertTrue(s.summary.contains("15min"), "and so is the logged walk: \(s.summary)")
    }

    func testSameActivityIsNotDoubleReported() throws {
        let auto = CheckInAutoFill.derive([CheckInAutoFill.WorkoutFact(type: .walk, durationMin: 32, incline: 4)])
        let manual = CheckInAutoFill.ManualFacts(workedOut: true, cardio: true,
                                                 cardioType: "Inclined Walk", cardioDuration: 30)
        let s = try XCTUnwrap(CheckInAutoFill.mergedDay(auto: auto, manual: manual))
        XCTAssertTrue(s.summary.contains("32min"), "the workout's numbers win")
        XCTAssertFalse(s.summary.contains("30min"), "the same walk isn't listed twice: \(s.summary)")
    }

    // MARK: reminder time strictness (overnight review, LOW)

    func testMalformedTimeNeverSchedulesAWrongHour() {
        let now = at(2026, 7, 29, 10)
        // "9pm" has no colon — must fall back to the 09:00 default (rolled
        // forward), never be half-read as hour 9 when the user meant 21:00.
        XCTAssertEqual(JeevesChatService.resolveFireDate(dateRaw: "today", timeRaw: "9pm", relativeTo: now),
                       at(2026, 7, 30, 9))
        XCTAssertEqual(JeevesChatService.resolveFireDate(dateRaw: "today", timeRaw: "23.30", relativeTo: now),
                       at(2026, 7, 30, 9))
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

    func testStripExpiryComparesWordingOnly() {
        // Re-stating a preference with a new expiry must replace it, not be
        // silently swallowed as a duplicate.
        XCTAssertEqual(StandingPrefs.stripExpiry("Gym is always at 7 PM (until 2026-09-12)"),
                       StandingPrefs.stripExpiry("Gym is always at 7 PM"))
    }

    // MARK: voice-note retention

    func testPruneCutoffIs30DaysBack() {
        let now = at(2026, 7, 29, 12)
        let cutoff = VoiceNoteSync.pruneCutoff(now: now)
        XCTAssertEqual(cutoff, at(2026, 6, 29, 12))
    }
}
