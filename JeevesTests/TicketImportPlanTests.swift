//
//  TicketImportPlanTests.swift
//  JeevesTests
//
//  The collision is the part worth testing hardest. The store this ships into
//  already contains a Bali trip 3–11 Sep with two leftover one-day stays on
//  the 5th and 7th — the audit reports them every morning — and the ticket
//  disagrees with all of it: Bali starts on the 4th, and the trip runs to the
//  14th because Singapore is three nights.
//

import XCTest
@testable import Jeeves

final class TicketImportPlanTests: XCTestCase {

    private func dc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> DateComponents {
        DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, zone: String = "Asia/Kolkata") -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private var realTicket: [TicketLeg] {
        [
            TicketLeg(flightNumber: "SQ 511", carrier: "Singapore Airlines", from: "BLR", to: "SIN",
                      departLocal: dc(2026, 9, 3, 23, 5), arriveLocal: dc(2026, 9, 4, 6, 10),
                      printedMinutes: 275),
            TicketLeg(flightNumber: "TR 8600", carrier: "Scoot", from: "SIN", to: "DPS",
                      departLocal: dc(2026, 9, 4, 7, 30), arriveLocal: dc(2026, 9, 4, 10, 20),
                      printedMinutes: 170),
            TicketLeg(flightNumber: "TR 8601", carrier: "Scoot", from: "DPS", to: "SIN",
                      departLocal: dc(2026, 9, 11, 11, 20), arriveLocal: dc(2026, 9, 11, 14, 10),
                      printedMinutes: 170),
            TicketLeg(flightNumber: "SQ 510", carrier: "Singapore Airlines", from: "SIN", to: "BLR",
                      departLocal: dc(2026, 9, 14, 20, 5), arriveLocal: dc(2026, 9, 14, 21, 50),
                      printedMinutes: 255),
        ]
    }

    private var itinerary: ResolvedItinerary {
        let (itin, _) = TicketItinerary.resolve(legs: realTicket)
        return itin!
    }

    // MARK: The shape

    func testTripSpansTheWholeItineraryAndIsNamedForWhereYouStay() {
        let plan = TicketImportPlanner.plan(from: itinerary)
        let p = try? XCTUnwrap(plan)
        XCTAssertEqual(p?.tripTitle, "Bali & Singapore")
        XCTAssertEqual(p?.action, .createTrip)
        XCTAssertEqual(p?.journeys.count, 4)
        XCTAssertEqual(p?.stays.count, 2, "Changi's 1h20 is a connection, not a stay")
        XCTAssertEqual(p?.dayCount, 12, "3 Sep through 14 Sep inclusive")
    }

    func testTheTripStartsOnTheDepartureDayNotTheArrivalDay() {
        // SQ 511 leaves Bengaluru at 23:05 on the 3rd and lands on the 4th.
        // The trip has to start on the 3rd — that is the day the traveller
        // stops being available for a normal plan.
        let plan = TicketImportPlanner.plan(from: itinerary)
        XCTAssertEqual(plan?.tripStart, day(2026, 9, 3))
    }

    func testBaliStartsOnTheFourthNotTheThird() {
        // The single most consequential date in the whole import: the ticket
        // puts the traveller in the air overnight, so Bali begins on the 4th.
        let plan = TicketImportPlanner.plan(from: itinerary)
        let bali = plan?.stays.first { $0.place == "Bali" }
        XCTAssertEqual(bali?.arriveDate, day(2026, 9, 4, zone: "Asia/Makassar"))
        XCTAssertEqual(bali?.departDate, day(2026, 9, 11, zone: "Asia/Makassar"))
        XCTAssertEqual(bali?.timeZoneID, "Asia/Makassar")
    }

    func testSingaporeIsAStayOnTheWayHome() {
        let plan = TicketImportPlanner.plan(from: itinerary)
        let sin = plan?.stays.first { $0.place == "Singapore" }
        XCTAssertEqual(sin?.arriveDate, day(2026, 9, 11, zone: "Asia/Singapore"))
        XCTAssertEqual(sin?.departDate, day(2026, 9, 14, zone: "Asia/Singapore"))
    }

    func testJourneysCarryTheirOwnClocks() {
        let plan = TicketImportPlanner.plan(from: itinerary)
        let first = try? XCTUnwrap(plan?.journeys.first)
        XCTAssertEqual(first?.label, "SQ 511")
        XCTAssertEqual(first?.fromTimeZoneID, "Asia/Kolkata")
        XCTAssertEqual(first?.toTimeZoneID, "Asia/Singapore")
        XCTAssertTrue(first?.fromPlace.contains("Kempegowda") ?? false)
    }

    /// This test used to assert 240 and cite the ticket: "check-in opens 4 h
    /// before international departures." The ticket does say that, and it is
    /// not a deadline — an opening time tells you the earliest you MAY arrive,
    /// never the latest you may. Stored as a cut-off it put the user at the
    /// terminal at 18:35 for SQ 511's 23:05 departure, four and a half hours
    /// early, on every imported international leg.
    ///
    /// An imported leg now starts from the same assumption as a hand-entered
    /// one, which is also what BLR itself advises.
    func testAnImportedLegDoesNotTreatTheCheckInOpeningTimeAsADeadline() {
        let plan = TicketImportPlanner.plan(from: itinerary)
        let first = plan?.journeys.first
        XCTAssertEqual(first?.checkInMinutes, 180)
        XCTAssertEqual(first?.checkInMinutes, TravelSegment.defaultInternationalCheckInMinutes,
                       "imported and hand-entered legs must not disagree about this")
    }

    // MARK: The collision

    private var existingBaliTrip: ExistingTrip {
        ExistingTrip(title: "Bali",
                     startDate: day(2026, 9, 3),
                     endDate: day(2026, 9, 11),
                     stays: [
                        .init(place: "Bali", arriveDate: day(2026, 9, 3), departDate: day(2026, 9, 11)),
                        .init(place: "Bali", arriveDate: day(2026, 9, 5), departDate: day(2026, 9, 5)),
                        .init(place: "Bali", arriveDate: day(2026, 9, 7), departDate: day(2026, 9, 7)),
                     ])
    }

    func testAnOverlappingTripIsUpdatedNotDuplicated() {
        let plan = TicketImportPlanner.plan(from: itinerary, existing: existingBaliTrip)
        guard case .updateTrip(let title, _, _) = plan?.action else {
            return XCTFail("a second overlapping trip is the failure this app has already had")
        }
        XCTAssertEqual(title, "Bali")
    }

    func testTheDifferencesAreStatedInPlainLanguage() {
        let plan = TicketImportPlanner.plan(from: itinerary, existing: existingBaliTrip)
        let notes = plan?.notes ?? []
        XCTAssertTrue(notes.contains { $0.contains("14 Sep") },
                      "the trip runs three days longer than stored — say so. Got: \(notes)")
        XCTAssertTrue(notes.contains { $0.contains("Singapore") },
                      "Singapore isn't in the stored trip at all. Got: \(notes)")
    }

    func testTheLeftoverOneDayStaysAreOfferedForRemoval() {
        let plan = TicketImportPlanner.plan(from: itinerary, existing: existingBaliTrip)
        let redundant = plan?.redundantStays ?? []
        XCTAssertEqual(redundant.count, 2, "the 5th and 7th sit wholly inside the real Bali stay")
        XCTAssertTrue(redundant.allSatisfy { $0.place == "Bali" })
    }

    func testAStayThatMerelyOverlapsIsNotTreatedAsRedundant() {
        // Conservative on purpose: a partly-overlapping stay may be a real
        // separate visit, and deleting it would be a guess.
        let existing = ExistingTrip(title: "Bali", startDate: day(2026, 9, 1), endDate: day(2026, 9, 11),
                                    stays: [.init(place: "Bali",
                                                  arriveDate: day(2026, 9, 1),
                                                  departDate: day(2026, 9, 6))])
        let plan = TicketImportPlanner.plan(from: itinerary, existing: existing)
        XCTAssertTrue(plan?.redundantStays.isEmpty ?? false)
    }

    func testNoExistingTripMeansCreateAndNoDeletions() {
        let plan = TicketImportPlanner.plan(from: itinerary)
        XCTAssertEqual(plan?.action, .createTrip)
        XCTAssertTrue(plan?.redundantStays.isEmpty ?? false)
        XCTAssertTrue(plan?.notes.isEmpty ?? false)
    }

    // MARK: Extraction decoding — the contract, without network

    func testDecodingTheModelsJSON() {
        let json = """
        Here is the itinerary:
        ```json
        {"legs":[{"flightNumber":"SQ 511","carrier":"Singapore Airlines","from":"BLR","to":"SIN",
        "departDate":"2026-09-03","departTime":"23:05","arriveDate":"2026-09-04","arriveTime":"06:10",
        "durationMinutes":275,"fromTerminal":null,"toTerminal":null}],
        "bookingReference":"AO261868215","airlineReference":"DOULTU",
        "passengers":["MR. ABHIMANYU SINGH"],"bookedByName":"Joy Holidays","bookedByPhone":"8989225239"}
        ```
        """
        let decoded = TicketExtractionService.decode(json)
        XCTAssertEqual(decoded?.legs.count, 1)
        XCTAssertEqual(decoded?.legs.first?.from, "BLR")
        XCTAssertEqual(decoded?.legs.first?.printedMinutes, 275)
        XCTAssertEqual(decoded?.legs.first?.departLocal.hour, 23)
        XCTAssertNil(decoded?.legs.first?.fromTerminal, "absent must stay absent")
    }

    func testTheAgentIsKeptApartFromTheTraveller() {
        let json = #"{"legs":[{"flightNumber":"SQ 511","from":"BLR","to":"SIN","departDate":"2026-09-03","departTime":"23:05","arriveDate":"2026-09-04","arriveTime":"06:10"}],"passengers":["MR. ABHIMANYU SINGH"],"bookedByName":"Joy Holidays","bookedByPhone":"8989225239"}"#
        let decoded = TicketExtractionService.decode(json)
        XCTAssertEqual(decoded?.booking.passengerNames, ["MR. ABHIMANYU SINGH"])
        XCTAssertEqual(decoded?.booking.bookedByPhone, "8989225239",
                       "the agent's number is the most useful button on a disruption screen")
    }

    func testRubbishDecodesToNothingRatherThanAHalfTicket() {
        XCTAssertNil(TicketExtractionService.decode("sorry, I couldn't read that"))
        XCTAssertNil(TicketExtractionService.decode(#"{"legs":[]}"#))
        // A leg with an unreadable time must sink the whole parse, not import
        // three legs of a four-leg trip.
        XCTAssertNil(TicketExtractionService.decode(
            #"{"legs":[{"flightNumber":"X","from":"BLR","to":"SIN","departDate":"nonsense","departTime":"23:05","arriveDate":"2026-09-04","arriveTime":"06:10"}]}"#))
    }

    func testComponentsRejectImpossibleClockReadings() {
        XCTAssertNil(TicketExtractionService.components(date: "2026-09-03", time: "25:00"))
        XCTAssertNil(TicketExtractionService.components(date: "2026-13-03", time: "10:00"))
        XCTAssertNotNil(TicketExtractionService.components(date: "2026-09-03", time: "00:05"))
    }

    func testOutermostJSONSurvivesBracesInsideStrings() {
        let text = #"{"legs":[],"note":"a } inside a string"}"#
        XCTAssertEqual(TicketExtractionService.outermostJSONObject("prose " + text + " more"), text)
    }

    func testAScannedPDFIsRejectedRatherThanSentEmpty() {
        XCTAssertFalse(TicketExtractionService.hasUsableText(nil))
        XCTAssertFalse(TicketExtractionService.hasUsableText("Boarding pass"))
        XCTAssertTrue(TicketExtractionService.hasUsableText(String(repeating: "a", count: 250)))
    }
}
