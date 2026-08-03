//
//  TravelCorrectnessTests.swift
//  JeevesTests
//
//  Six defects found by walking five real ingestion scenarios against HEAD.
//  The two fixtures are the ones that exposed them:
//
//    August  — JLR Kabini 18–20 Aug, JLR Bandipur 20–23 Aug 2026. A driving
//              trip with a handover day and no flights anywhere.
//    September — Bali 4–11 Sep, Singapore 11–14 Sep 2026, later joined by a
//              ticket. The same shape, where every road assumption is wrong.
//
//  Each test below pins a blind spot as well as a capability, so nobody later
//  reads a check as stronger than it is.
//

import XCTest
@testable import Jeeves

final class TravelCorrectnessTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func span(_ place: String, _ from: (Int, Int, Int), _ to: (Int, Int, Int),
                      address: String = "", unsettled: Bool = true) -> Itinerary.Span {
        Itinerary.Span(place: place,
                       start: day(from.0, from.1, from.2),
                       end: day(to.0, to.1, to.2),
                       address: address,
                       endIsUnsettled: unsettled)
    }

    // MARK: - A stay's end has one meaning

    /// Kabini 18–20 + Bandipur 20–23. The move on the 20th proves the 19th was
    /// Kabini's last night, so that end is settled. Nothing follows Bandipur,
    /// so its end is still whatever the calendar said.
    func testAFollowedStayGetsASettledEndAndTheLastOneDoesNot() {
        let resolved = Itinerary.resolveOverlaps(
            [span("Kabini", (2026, 8, 18), (2026, 8, 20)),
             span("Bandipur", (2026, 8, 20), (2026, 8, 23))],
            calendar: cal)

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].end, day(2026, 8, 19),
                       "moving on the 20th makes the 19th the last night at Kabini")
        XCTAssertFalse(resolved[0].endIsUnsettled,
                       "a stay you moved out of has a settled end")
        XCTAssertTrue(resolved[1].endIsUnsettled,
                      "nothing follows Bandipur, so its end is still the calendar's guess")
    }

    /// Two nights at Kabini — the 18th and the 19th — stated as one number
    /// because it is known. Bandipur is three or four and must say so.
    func testNightsAreExactWhenSettledAndAPairWhenNot() {
        let resolved = Itinerary.resolveOverlaps(
            [span("Kabini", (2026, 8, 18), (2026, 8, 20)),
             span("Bandipur", (2026, 8, 20), (2026, 8, 23))],
            calendar: cal)

        XCTAssertEqual(Itinerary.nights(resolved[0], calendar: cal), 2)
        XCTAssertEqual(Itinerary.nightsRange(resolved[0], calendar: cal), 2...2)

        XCTAssertEqual(Itinerary.nightsRange(resolved[1], calendar: cal), 3...4,
                       "the 23rd is either a last night or the morning you leave")
    }

    /// THE BLIND SPOT. Nothing here can tell which of the two readings is
    /// right — only a document can. Pinned so the range is never quietly
    /// collapsed to its lower end because that looks tidier.
    func testAnUnsettledEndCannotBeResolvedFromTheCalendarAlone() {
        let onlyStay = span("Bali", (2026, 9, 4), (2026, 9, 11))
        let resolved = Itinerary.resolveOverlaps([onlyStay], calendar: cal)

        XCTAssertTrue(resolved[0].endIsUnsettled)
        XCTAssertEqual(Itinerary.nightsRange(resolved[0], calendar: cal), 7...8,
                       "a lone all-day block is genuinely ambiguous by one night")
    }

    /// The September fixture, where a later stay settles the earlier one:
    /// Singapore starting on the 11th makes the 10th Bali's last night, which
    /// is exactly what TR 8601's 11:20 departure independently confirms.
    func testSingaporeStartingOnTheEleventhSettlesBaliAtSevenNights() {
        let resolved = Itinerary.resolveOverlaps(
            [span("Bali", (2026, 9, 4), (2026, 9, 11)),
             span("Singapore", (2026, 9, 11), (2026, 9, 14))],
            calendar: cal)

        XCTAssertEqual(resolved[0].end, day(2026, 9, 10))
        XCTAssertEqual(Itinerary.nightsRange(resolved[0], calendar: cal), 7...7,
                       "nights of the 4th to the 10th — the ticket's 169 h layover agrees")
    }

    // MARK: - Detecting a trip that has no address

    private func candidate(_ title: String, _ d: (Int, Int, Int),
                           hasLocation: Bool, spanDays: Int,
                           isAllDay: Bool = true,
                           ownSpanDays: Int? = nil) -> TravelDetection.Candidate {
        TravelDetection.Candidate(title: title, day: day(d.0, d.1, d.2),
                                  isAllDay: isAllDay, hasLocation: hasLocation,
                                  eventMinutes: 0, journeyMinutes: nil, spanDays: spanDays,
                                  ownSpanDays: ownSpanDays ?? spanDays)
    }

    /// A daily standup, synced for five days. `spanDays` is inferred across
    /// every same-titled row in the store, so it arrives as 5 — but each row
    /// covers one day, and a timed meeting is never a place-window. The first
    /// cut of this rule proposed switching a working week to travel mode.
    func testADailyRecurringMeetingIsNotATrip() {
        XCTAssertNil(TravelDetection.suggestion(
            for: [candidate("Standup", (2026, 8, 10), hasLocation: false,
                            spanDays: 5, isAllDay: false, ownSpanDays: 1)],
            calendar: cal))
    }

    /// A 21:00–01:00 party is stored with an end date on the next day, so its
    /// own span is 2. All-day is what separates a place-window from a night out.
    func testAnEventCrossingMidnightIsNotATrip() {
        XCTAssertNil(TravelDetection.suggestion(
            for: [candidate("Party", (2026, 8, 10), hasLocation: false,
                            spanDays: 2, isAllDay: false, ownSpanDays: 2)],
            calendar: cal))
    }

    /// An all-day title repeated on consecutive days still needs its OWN span.
    func testAnInferredSpanAloneDoesNotMakeATrip() {
        XCTAssertNil(TravelDetection.suggestion(
            for: [candidate("Fast", (2026, 8, 10), hasLocation: false,
                            spanDays: 5, isAllDay: true, ownSpanDays: 1)],
            calendar: cal))
    }

    /// "Bali 4–11 Sep" as a bare title reached none of the old rules, so eight
    /// days were filled with the Bengaluru routine and notified for.
    func testAMultiDayBlockWithNoAddressIsNowDetected() {
        let s = TravelDetection.suggestion(
            for: [candidate("Bali", (2026, 9, 4), hasLocation: false, spanDays: 8)],
            calendar: cal)

        XCTAssertNotNil(s, "eight days in one place is not eight ordinary days")
        XCTAssertEqual(s?.startDay, day(2026, 9, 4))
        XCTAssertEqual(s?.endDay, day(2026, 9, 11))
    }

    /// It PROPOSES. A multi-day block with no address is also how people record
    /// a sprint or a course, so it must never switch the days by itself.
    func testTheNoAddressRuleIsWeak() {
        let s = TravelDetection.suggestion(
            for: [candidate("Bali", (2026, 9, 4), hasLocation: false, spanDays: 8)],
            calendar: cal)
        XCTAssertEqual(s?.isStrong, false)
    }

    /// A block that HAS an address still wins, so the reason the user reads is
    /// the strongest true one rather than whichever rule happened to run first.
    func testAnAddressedBlockStillTakesPrecedence() {
        let s = TravelDetection.suggestion(
            for: [candidate("Bali", (2026, 9, 4), hasLocation: false, spanDays: 8),
                  candidate("Karma Kandara", (2026, 9, 4), hasLocation: true, spanDays: 8)],
            calendar: cal)

        XCTAssertEqual(s?.title, "Karma Kandara")
        XCTAssertEqual(s?.isStrong, true)
    }

    /// A single day with no address is still nothing. Without this the rule
    /// would fire on every ordinary appointment.
    func testASingleDayWithNoAddressIsStillNotATrip() {
        XCTAssertNil(TravelDetection.suggestion(
            for: [candidate("Dentist", (2026, 8, 5), hasLocation: false, spanDays: 1)],
            calendar: cal))
    }

    // MARK: - Refusing to route a word that isn't a place

    func testThePlaceholderHomeIsNotARoutableOrigin() {
        XCTAssertNil(RoutableOrigin.address("Home"))
        XCTAssertNil(RoutableOrigin.address("home"))
        XCTAssertNil(RoutableOrigin.address("  Home  "))
        XCTAssertNil(RoutableOrigin.address(""))
        XCTAssertNil(RoutableOrigin.address(nil))
        XCTAssertNil(RoutableOrigin.address("Office"))
    }

    /// A real address survives, including one that merely contains the word.
    /// The match is on the whole string, not a substring.
    func testARealAddressPassesThrough() {
        XCTAssertEqual(RoutableOrigin.address("1 Homestead Road, Koramangala"),
                       "1 Homestead Road, Koramangala")
        XCTAssertEqual(RoutableOrigin.address(" Karma Kandara, Ungasan "),
                       "Karma Kandara, Ungasan")
    }

    // MARK: - Not calling every transfer a drive

    private func route(minutes: Int, metres: Int?) -> GoogleMapsService.Route {
        GoogleMapsService.Route(minutes: minutes, metres: metres)
    }

    /// Kabini → Bandipur. Real OSRM free-flow is about 1 h 29 over 98.6 km.
    func testAKarnatakaLodgeTransferIsADrive() {
        let v = TransferMode.classify(route: route(minutes: 95, metres: 98_591))
        XCTAssertEqual(v, .drive(minutes: 95))
        XCTAssertTrue(TransferMode.settlesTheAssumption(v))
        XCTAssertNil(TransferMode.note(for: v, from: "Kabini", to: "Bandipur"))
    }

    /// Bali → Singapore. The Routes API has no road answer across the Java Sea,
    /// and the assumption must survive as an assumption rather than becoming a
    /// different guess.
    func testAnUnroutablePairDoesNotSettleTheAssumption() {
        let v = TransferMode.classify(route: nil)
        XCTAssertEqual(v, .notRoutableByRoad)
        XCTAssertFalse(TransferMode.settlesTheAssumption(v))
        XCTAssertNotNil(TransferMode.note(for: v, from: "Bali", to: "Singapore"))
    }

    /// A route that comes back absurdly long is the same class of answer as no
    /// route at all: do not call it a drive.
    func testAnAbsurdlyLongRoadRouteIsRefused() {
        let v = TransferMode.classify(route: route(minutes: 40 * 60, metres: 3_400_000))
        XCTAssertEqual(v, .tooFarToDrive(minutes: 2400))
        XCTAssertFalse(TransferMode.settlesTheAssumption(v))
    }

    /// The boundary, pinned. Ten hours is still a drive; a minute more is not.
    func testThePlausibleDriveBoundary() {
        XCTAssertTrue(TransferMode.settlesTheAssumption(
            TransferMode.classify(route: route(minutes: 600, metres: nil))))
        XCTAssertFalse(TransferMode.settlesTheAssumption(
            TransferMode.classify(route: route(minutes: 601, metres: nil))))
    }

    // MARK: - Distance now survives the field mask

    func testDistanceIsParsedAlongsideDuration() {
        let json = #"{"routes":[{"duration":"5325s","distanceMeters":98591}]}"#.data(using: .utf8)!
        let r = GoogleMapsService.parseRoute(json)
        XCTAssertEqual(r?.minutes, 89)
        XCTAssertEqual(r?.metres, 98_591)
        XCTAssertEqual(r?.kilometres ?? 0, 98.591, accuracy: 0.001)
    }

    /// A response with no distance is still usable — the duration is the thing
    /// leave-by needs. Callers wanting kilometres get nil, never a zero.
    func testAMissingDistanceIsNotAFailure() {
        let json = #"{"routes":[{"duration":"5325s"}]}"#.data(using: .utf8)!
        let r = GoogleMapsService.parseRoute(json)
        XCTAssertEqual(r?.minutes, 89)
        XCTAssertNil(r?.metres)
        XCTAssertNil(r?.kilometres)
    }

    /// The old entry point still behaves, so nothing that only wants minutes
    /// had to change.
    func testParseMinutesStillWorks() {
        let json = #"{"routes":[{"duration":"2491s","distanceMeters":40100}]}"#.data(using: .utf8)!
        XCTAssertEqual(GoogleMapsService.parseMinutes(json), 42)
    }

    func testAnErrorBodyParsesToNil() {
        let json = #"{"error":{"code":400,"message":"bad"}}"#.data(using: .utf8)!
        XCTAssertNil(GoogleMapsService.parseRoute(json))
        XCTAssertNil(GoogleMapsService.parseMinutes(json))
    }

    // MARK: - The imported-flight check-in assumption

    /// SQ 511 departs 23:05. The old 240 put the user at the terminal at 18:35,
    /// four and a half hours early, every time. "Check-in opens 4 h before" is
    /// not a deadline.
    func testAnImportedFlightUsesTheAirlineGuidanceNotTheOpeningTime() {
        XCTAssertEqual(TravelSegment.defaultInternationalCheckInMinutes, 180)

        let depart = cal.date(from: DateComponents(year: 2026, month: 9, day: 3,
                                                  hour: 23, minute: 5))!
        let plan = LeaveBy.forFlight(departAt: depart,
                                     checkInMinutes: TravelSegment.defaultInternationalCheckInMinutes,
                                     securityMinutes: 30, travelMinutes: 95, bufferMinutes: 20)

        // 23:05 − 3 h = 20:05 cut-off; − 30 security = 19:35 at the terminal;
        // − 95 drive = 18:00; − 20 buffer = 17:40.
        XCTAssertEqual(plan.leaveAt,
                       cal.date(from: DateComponents(year: 2026, month: 9, day: 3,
                                                     hour: 17, minute: 40)))
    }

    // MARK: - How old is a measurement

    /// A FLIGHT carries a departure. Its fixture must set departAt.
    private func flight(departingIn hours: Double) -> TravelSegment {
        TravelSegment(tripID: UUID(), mode: .flight, label: "SQ 511",
                      departAt: Date().addingTimeInterval(hours * 3600))
    }

    /// A DRIVE carries an arrive-by and leaves departAt at .distantPast — which
    /// is how the app actually creates every transfer. The first version of
    /// these tests used a drive with a departAt, a shape nothing in the app
    /// produces, so they passed while `.predicted` was unreachable for every
    /// real drive on the branch.
    private func drive(arrivingIn hours: Double) -> TravelSegment {
        TravelSegment(tripID: UUID(), mode: .drive, label: "Kabini → Bandipur",
                      arriveBy: Date().addingTimeInterval(hours * 3600))
    }

    func testAnUnmeasuredSegmentIsNever() {
        XCTAssertEqual(drive(arrivingIn: 2).freshness(), .never)
        XCTAssertEqual(flight(departingIn: 2).freshness(), .never)
    }

    /// Measuring sixteen days out is a forecast of a road nobody has driven.
    func testAMeasurementTakenLongBeforeAFlightIsPredicted() {
        let s = flight(departingIn: 16 * 24)
        s.record(minutes: 95)
        guard case .predicted(let days) = s.freshness() else {
            return XCTFail("expected a prediction, got \(s.freshness())")
        }
        XCTAssertEqual(days, 16)
    }

    /// THE ONE THAT MATTERED. A drive created the way acceptTravel creates it —
    /// arriveBy set, departAt untouched — must still be able to be a forecast.
    func testADriveMeasuredLongBeforeItsArriveByIsPredicted() {
        let s = drive(arrivingIn: 16 * 24)
        XCTAssertEqual(s.departAt, .distantPast, "the shape the app really makes")
        s.record(minutes: 95)
        guard case .predicted(let days) = s.freshness() else {
            return XCTFail("a drive must be able to be a forecast, got \(s.freshness())")
        }
        XCTAssertEqual(days, 16)
    }

    func testAMeasurementNearTheJourneyIsLive() {
        let s = drive(arrivingIn: 2)
        s.record(minutes: 95)
        guard case .live(let age) = s.freshness() else {
            return XCTFail("expected a live reading, got \(s.freshness())")
        }
        XCTAssertLessThanOrEqual(age, 1)
    }

    /// A drive with no arrive-by at all has no anchor to reckon against, and
    /// must not silently claim to be a forecast.
    func testAnAnchorlessSegmentIsLiveNotPredicted() {
        let s = TravelSegment(tripID: UUID(), mode: .drive, label: "x")
        s.record(minutes: 30)
        guard case .live = s.freshness() else {
            return XCTFail("no anchor means no forecast claim, got \(s.freshness())")
        }
    }

    // MARK: - Recording settles the mode, except when it shouldn't

    func testAPlausibleDriveSettlesTheAssumedMode() {
        let s = TravelSegment(tripID: UUID(), mode: .drive, label: "x",
                              arriveBy: Date().addingTimeInterval(3600),
                              modeIsAssumed: true)
        s.record(minutes: 95)
        XCTAssertFalse(s.modeIsAssumed, "a road answer is evidence the mode was right")
    }

    /// An eleven-hour road answer is a real measurement and not evidence of a
    /// drive. Keeping the minutes while keeping the doubt is the whole point —
    /// discarding them traded a silent wrong answer for a silent missing one.
    func testATooFarRoadAnswerKeepsItsMinutesAndItsDoubt() {
        let s = TravelSegment(tripID: UUID(), mode: .drive, label: "x",
                              arriveBy: Date().addingTimeInterval(3600),
                              modeIsAssumed: true)
        s.record(minutes: 660, settlesMode: false)
        XCTAssertEqual(s.travelMinutes, 660)
        XCTAssertFalse(s.travelIsEstimated)
        XCTAssertTrue(s.modeIsAssumed, "still nobody's choice")
    }

    /// record() is the only way in — it sets all three fields together. Setting
    /// minutes by hand and forgetting the timestamp is the bug it prevents.
    func testRecordSetsEveryFieldAtOnce() {
        let s = flight(departingIn: 3)
        XCTAssertTrue(s.travelIsEstimated)
        XCTAssertNil(s.measuredAt)

        s.record(minutes: 42)

        XCTAssertEqual(s.travelMinutes, 42)
        XCTAssertFalse(s.travelIsEstimated)
        XCTAssertNotNil(s.measuredAt)
    }

    // MARK: - A move between two address-less stays still exists

    /// Bali and Singapore as bare titles: two stays, no addresses, and a
    /// handover on the 11th. The transition guard tested
    /// `from.address != to.address`, which is FALSE when both are empty — so
    /// the only journey of the trip existed nowhere, and the refutation this
    /// branch built for exactly that pair could never run.
    func testTwoAddresslessStaysStillProduceAMove() {
        let resolved = Itinerary.resolveOverlaps(
            [span("Bali", (2026, 9, 4), (2026, 9, 11)),
             span("Singapore", (2026, 9, 11), (2026, 9, 14))],
            calendar: cal)
        let moves = Itinerary.transitions(resolved)

        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].day, day(2026, 9, 11))
        XCTAssertEqual(moves[0].from.place, "Bali")
        XCTAssertEqual(moves[0].to.place, "Singapore")
        XCTAssertTrue(moves[0].from.address.isEmpty)
        XCTAssertTrue(moves[0].to.address.isEmpty,
                      "both blank — and the move is still real")
    }
}
