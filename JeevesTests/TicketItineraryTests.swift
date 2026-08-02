//
//  TicketItineraryTests.swift
//  JeevesTests
//
//  The fixture is the real booking: SQ 511 / TR 8600 / TR 8601 / SQ 510,
//  Bengaluru → Singapore → Bali and back, 3–14 September 2026. Every time in
//  it is printed on its own city's clock with no offset anywhere on the page,
//  which is the entire difficulty.
//

import XCTest
@testable import Jeeves

final class TicketItineraryTests: XCTestCase {

    private func dc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> DateComponents {
        DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)
    }

    /// The ticket, verbatim.
    private var realTicket: [TicketLeg] {
        [
            TicketLeg(flightNumber: "SQ 511", carrier: "Singapore Airlines",
                      from: "BLR", to: "SIN",
                      departLocal: dc(2026, 9, 3, 23, 5),
                      arriveLocal: dc(2026, 9, 4, 6, 10),
                      printedMinutes: 275),                 // 4h 35m
            TicketLeg(flightNumber: "TR 8600", carrier: "Scoot",
                      from: "SIN", to: "DPS",
                      departLocal: dc(2026, 9, 4, 7, 30),
                      arriveLocal: dc(2026, 9, 4, 10, 20),
                      printedMinutes: 170),                 // 2h 50m
            TicketLeg(flightNumber: "TR 8601", carrier: "Scoot",
                      from: "DPS", to: "SIN",
                      departLocal: dc(2026, 9, 11, 11, 20),
                      arriveLocal: dc(2026, 9, 11, 14, 10),
                      printedMinutes: 170),
            TicketLeg(flightNumber: "SQ 510", carrier: "Singapore Airlines",
                      from: "SIN", to: "BLR",
                      departLocal: dc(2026, 9, 14, 20, 5),
                      arriveLocal: dc(2026, 9, 14, 21, 50),
                      printedMinutes: 255),                 // 4h 15m
        ]
    }

    // MARK: The self-check

    func testRealTicketReconcilesAgainstItsOwnDurations() {
        let (itin, problems) = TicketItinerary.resolve(legs: realTicket)
        let fatal = problems.filter(\.isFatal)
        XCTAssertTrue(fatal.isEmpty, "unexpected fatal problems: \(fatal.map(\.message))")
        let itinerary = try? XCTUnwrap(itin)
        XCTAssertEqual(itinerary?.legs.count, 4)

        // Every leg's UTC span equals what the ticket printed. BLR→SIN looks
        // like 7h05 on the page (23:05 to 06:10) and is really 4h35 — the
        // 2h30 offset is the whole test.
        for leg in itinerary?.legs ?? [] {
            XCTAssertEqual(leg.elapsedMinutes, leg.leg.printedMinutes,
                           "\(leg.leg.flightNumber) computed \(leg.elapsedMinutes) vs printed \(leg.leg.printedMinutes ?? -1)")
        }
    }

    func testAWrongTimezoneIsCaughtByTheDurationNotByAHuman() {
        // Read BLR as UTC+8 instead of +5:30 and leg 1 computes to 1h 35m
        // against a printed 4h 35m. Nothing on the ticket says the offset, so
        // this arithmetic is the only thing standing between a typo in a
        // lookup table and a leave-by three hours wrong.
        var leg = realTicket[0]
        leg.from = "SIN"   // stands in for "BLR resolved to the wrong zone"
        let (itin, problems) = TicketItinerary.resolve(legs: [leg])
        XCTAssertNil(itin, "an itinerary that fails its own arithmetic must not be produced")
        XCTAssertTrue(problems.contains { if case .durationMismatch = $0 { return true }; return false },
                      "expected a duration mismatch, got \(problems.map(\.message))")
    }

    func testUnknownAirportStopsTheImportRatherThanGuessing() {
        var leg = realTicket[0]
        leg.from = "ZZZ"
        let (itin, problems) = TicketItinerary.resolve(legs: [leg])
        XCTAssertNil(itin)
        XCTAssertEqual(problems.first, .unknownAirport("ZZZ"))
        XCTAssertTrue(problems.first?.isFatal ?? false,
                      "defaulting an unknown airport to the device's zone would be silent and wrong")
    }

    // MARK: Shape

    func testTheChangiGapIsAConnectionAndBaliIsAStay() {
        let (itin, _) = TicketItinerary.resolve(legs: realTicket)
        let gaps = itin?.layovers ?? []
        XCTAssertEqual(gaps.count, 3)

        XCTAssertEqual(gaps[0].at, "SIN")
        XCTAssertEqual(gaps[0].kind, .connection)
        XCTAssertEqual(gaps[0].minutes, 80, "1h 20m at Changi")

        XCTAssertEqual(gaps[1].at, "DPS")
        XCTAssertEqual(gaps[1].kind, .stay, "seven nights in Bali is the destination, not a layover")

        XCTAssertEqual(gaps[2].at, "SIN")
        XCTAssertEqual(gaps[2].kind, .stay, "77h in Singapore is a stay even though the ticket calls it a layover")

        XCTAssertEqual(itin?.stays.count, 2)
        XCTAssertEqual(itin?.connections.count, 1)
    }

    func testTheTightConnectionIsFlaggedButDoesNotBlock() {
        let (itin, problems) = TicketItinerary.resolve(legs: realTicket)
        XCTAssertNotNil(itin, "the airline sold this connection; flagging it must not stop the import")
        XCTAssertTrue(problems.contains { if case .impossibleConnection = $0 { return true }; return false })
        XCTAssertFalse(problems.contains(where: \.isFatal))
    }

    func testAMissingTerminalIsNotTheSameTerminal() {
        var legs = realTicket
        legs[0].toTerminal = "3"
        // leg 1 departure terminal deliberately unknown
        let (itin, _) = TicketItinerary.resolve(legs: legs)
        XCTAssertNil(itin?.layovers.first?.changesTerminal,
                     "unknown must stay unknown — treating it as same-terminal silently clears a Skytrain transfer")

        legs[1].fromTerminal = "1"
        let (both, _) = TicketItinerary.resolve(legs: legs)
        XCTAssertEqual(both?.layovers.first?.changesTerminal, true)
    }

    // MARK: Ordering

    func testLegsThatOverlapInUTCAreRejected() {
        var legs = Array(realTicket.prefix(2))
        // Push the Bali departure to before the Singapore arrival.
        legs[1].departLocal = dc(2026, 9, 4, 5, 30)
        legs[1].arriveLocal = dc(2026, 9, 4, 8, 20)
        let (itin, problems) = TicketItinerary.resolve(legs: legs)
        XCTAssertNil(itin)
        XCTAssertTrue(problems.contains { if case .legsOutOfOrder = $0 { return true }; return false })
    }

    func testEmptyTicket() {
        let (itin, problems) = TicketItinerary.resolve(legs: [])
        XCTAssertNil(itin)
        XCTAssertEqual(problems, [.noLegs])
    }

    // MARK: Formatting

    func testDurationLabelCoversBothShapesTheUINeeds() {
        XCTAssertEqual(TicketItinerary.durationLabel(42), "42 min")
        XCTAssertEqual(TicketItinerary.durationLabel(180), "3h 00m")
        XCTAssertEqual(TicketItinerary.durationLabel(275), "4h 35m")
        XCTAssertEqual(TicketItinerary.durationLabel(0), "0 min")
        XCTAssertEqual(TicketItinerary.durationLabel(-5), "0 min")
    }

    // MARK: The directory

    func testAirportZones() {
        XCTAssertEqual(AirportDirectory.timeZone("BLR")?.identifier, "Asia/Kolkata")
        XCTAssertEqual(AirportDirectory.timeZone("SIN")?.identifier, "Asia/Singapore")
        XCTAssertEqual(AirportDirectory.timeZone("DPS")?.identifier, "Asia/Makassar")
        XCTAssertEqual(AirportDirectory.timeZone("blr ")?.identifier, "Asia/Kolkata", "tickets are not tidy")
        XCTAssertNil(AirportDirectory.timeZone("ZZZ"))
        XCTAssertEqual(AirportDirectory.name("ZZZ"), "ZZZ", "an unknown code still needs a label")
    }

    func testEveryAirportInTheDirectoryResolvesToARealZone() {
        for (code, airport) in AirportDirectory.all {
            XCTAssertNotNil(TimeZone(identifier: airport.timeZoneID),
                            "\(code) has an unusable zone identifier '\(airport.timeZoneID)'")
            XCTAssertEqual(code, code.uppercased(), "keys must be uppercase for lookup to work")
        }
    }
}
