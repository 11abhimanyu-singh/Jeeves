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

    func testAnOffsetChangingZoneErrorIsCaughtByTheDuration() {
        // The class the check DOES catch: a wrong zone that changes the
        // difference between the two offsets. BKK is +7, so leg 1's printed
        // 4h 35m no longer reconciles.
        var leg = realTicket[0]
        leg.from = "BKK"
        let (itin, problems) = TicketItinerary.resolve(legs: [leg])
        XCTAssertNil(itin, "an itinerary that fails its own arithmetic must not be produced")
        XCTAssertTrue(problems.contains { if case .durationMismatch = $0 { return true }; return false },
                      "expected a duration mismatch, got \(problems.map(\.message))")
    }

    func testTheDurationCheckIsBlindToASameOffsetZoneError() {
        // The class it does NOT catch, pinned so nobody re-reads the check as
        // stronger than it is. Colombo is also +5:30, so substituting it for
        // Bengaluru reconciles perfectly against the same printed duration.
        var leg = realTicket[0]
        leg.from = "CMB"
        let (itin, problems) = TicketItinerary.resolve(legs: [leg])
        XCTAssertNotNil(itin, "same-offset substitution passes — this is a real blind spot")
        XCTAssertFalse(problems.contains { if case .durationMismatch = $0 { return true }; return false })
    }

    func testASameZoneLegIsMarkedUnverifiedRatherThanTrusted() {
        // BLR→DEL is entirely inside Asia/Kolkata, so the duration constrains
        // nothing. The leg still resolves; it just must not claim to be checked.
        let domestic = TicketLeg(flightNumber: "6E 2044", carrier: "IndiGo",
                                 from: "BLR", to: "DEL",
                                 departLocal: dc(2026, 9, 3, 23, 5),
                                 arriveLocal: dc(2026, 9, 4, 2, 5),
                                 printedMinutes: 180)
        let (itin, _) = TicketItinerary.resolve(legs: [domestic])
        XCTAssertEqual(itin?.legs.first?.zonesVerified, false,
                       "a same-offset leg is not verified by its duration")
    }

    func testHalfOfTheRealTicketCannotBeVerifiedAtAll() {
        // Worth stating plainly, because it is the honest measure of how much
        // the duration check buys on a real booking:
        //   BLR(+5:30) → SIN(+8)   offsets differ  → verified
        //   SIN(+8)    → DPS(+8)   SAME offset     → NOT verified
        //   DPS(+8)    → SIN(+8)   SAME offset     → NOT verified
        //   SIN(+8)    → BLR(+5:30) offsets differ → verified
        // Singapore and Makassar are both UTC+8, so two of these four legs are
        // arithmetically unverifiable however carefully the check is written.
        let (itin, _) = TicketItinerary.resolve(legs: realTicket)
        let verified = itin?.legs.map(\.zonesVerified)
        XCTAssertEqual(verified, [true, false, false, true])
    }

    func testALegWithNoPrintedDurationIsNotSilentlyTreatedAsChecked() {
        var leg = realTicket[0]
        leg.printedMinutes = nil
        let (itin, _) = TicketItinerary.resolve(legs: [leg])
        XCTAssertNotNil(itin, "a ticket without durations is still importable")
        XCTAssertEqual(itin?.legs.first?.zonesVerified, false,
                       "unverifiable must be visible, not silent")
    }

    func testADroppedLegIsCaughtRatherThanBecomingAPhantomConnection() {
        // Chronology alone let this through: BLR→SIN then CGK→DPS resolved
        // cleanly and invented a connection at Singapore.
        let legs = [
            realTicket[0],
            TicketLeg(flightNumber: "TR 8600", carrier: "Scoot", from: "CGK", to: "DPS",
                      departLocal: dc(2026, 9, 4, 10, 0), arriveLocal: dc(2026, 9, 4, 12, 50),
                      printedMinutes: 110),
        ]
        let (itin, problems) = TicketItinerary.resolve(legs: legs)
        XCTAssertNil(itin)
        XCTAssertTrue(problems.contains { if case .brokenChain = $0 { return true }; return false },
                      "got \(problems.map(\.message))")
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
