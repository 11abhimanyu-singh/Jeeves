//
//  PlanCoordinatorTests.swift
//  JeevesTests
//
//  The commute-leg departure logic is pure, so it's fully unit-testable in
//  the fast suite. These lock in that each leg's departure minute is derived
//  from the day's anchors — that's what makes commute estimates use Google's
//  PREDICTED traffic for the actual departure time instead of traffic at the
//  moment the plan is generated.
//

import XCTest
@testable import Jeeves

final class PlanCoordinatorTests: XCTestCase {

    private func event(_ start: Int, _ end: Int, title: String = "Appt") -> DailyEvent {
        DailyEvent(date: Date().startOfDay, title: title, startMinute: start, endMinute: end,
                   destinationAddress: "somewhere", outboundStart: .home, source: .manual)
    }

    // MARK: Gym legs

    func testHomeToGymLeavesFiftyMinutesBeforeWeights() {
        // 30-min commute + 20-min mobility before the weights start.
        XCTAssertEqual(PlanCoordinator.legDepartureMinute(label: "Home→Gym", gymMinute: 19 * 60, events: []),
                       19 * 60 - 50)
    }

    func testGymToHomeLeavesAfterWeightsAndCardio() {
        // 70-min weights + 35-min cardio, then drive home.
        XCTAssertEqual(PlanCoordinator.legDepartureMinute(label: "Gym→Home", gymMinute: 19 * 60, events: []),
                       19 * 60 + 105)
    }

    func testGymLegsWithoutGymTimeHaveNoDeparture() {
        XCTAssertNil(PlanCoordinator.legDepartureMinute(label: "Home→Gym", gymMinute: nil, events: []))
        XCTAssertNil(PlanCoordinator.legDepartureMinute(label: "Gym→Home", gymMinute: nil, events: []))
    }

    // MARK: Event legs

    func testEventOutboundLeavesBeforeTheEvent() {
        let e = event(14 * 60, 15 * 60, title: "Dr Sree Lakshmi")
        XCTAssertEqual(PlanCoordinator.legDepartureMinute(label: "Home→Dr Sree Lakshmi", gymMinute: nil, events: [e]),
                       14 * 60 - 45)
    }

    func testEventReturnLeavesAtEventEnd() {
        let e = event(14 * 60, 15 * 60, title: "Dr Sree Lakshmi")
        XCTAssertEqual(PlanCoordinator.legDepartureMinute(label: "Dr Sree Lakshmi→Home", gymMinute: nil, events: [e]),
                       15 * 60)
    }

    func testUnknownLegHasNoDeparture() {
        XCTAssertNil(PlanCoordinator.legDepartureMinute(label: "Home→Nowhere", gymMinute: nil, events: []))
    }

    /// A calendar event literally titled "Gym" (a common calendar entry) must
    /// be priced by ITS times — not mistaken for the gym-anchor commute legs.
    func testEventTitledGymIsNotMistakenForGymAnchor() {
        let e = event(19 * 60, 20 * 60, title: "Gym")
        XCTAssertEqual(PlanCoordinator.legDepartureMinute(label: "Home→Gym", gymMinute: 11 * 60, events: [e]),
                       19 * 60 - 45, "event leg wins over the gym-anchor pattern")
        XCTAssertEqual(PlanCoordinator.legDepartureMinute(label: "Gym→Home", gymMinute: 11 * 60, events: [e]),
                       20 * 60, "return leg uses the event's end, not gym + 105")
    }

    // MARK: Leg wiring (labels ↔ departures), no network

    private func location(_ kind: LocationKind, _ address: String) -> SavedLocation {
        let l = SavedLocation(kind: kind)
        l.address = address
        return l
    }

    func testCommuteLegsAttachDeparturesToEveryLeg() throws {
        let cal = Calendar.current
        let day = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 7, day: 22)))
        let e = event(14 * 60, 15 * 60, title: "Dr Sree Lakshmi")
        let legs = PlanCoordinator.commuteLegs(.init(
            hasGym: true, gymMinute: 19 * 60, events: [e],
            locations: [location(.home, "12 Home St"), location(.gym, "Iron Works")],
            prepSessions: [], planDate: day))

        XCTAssertEqual(legs.map(\.label), ["Home→Gym", "Gym→Home", "Home→Dr Sree Lakshmi", "Dr Sree Lakshmi→Home"])
        for leg in legs {
            let dep = try XCTUnwrap(leg.departure, "\(leg.label) must carry a scheduled departure")
            let comps = cal.dateComponents([.day, .hour, .minute], from: dep)
            XCTAssertEqual(comps.day, 22, "\(leg.label) departs on the plan date")
        }
        // Spot-check the minutes: Home→Gym at 18:10, event outbound at 13:15.
        let gymDep = cal.dateComponents([.hour, .minute], from: legs[0].departure!)
        XCTAssertEqual(gymDep.hour, 18); XCTAssertEqual(gymDep.minute, 10)
        let apptDep = cal.dateComponents([.hour, .minute], from: legs[2].departure!)
        XCTAssertEqual(apptDep.hour, 13); XCTAssertEqual(apptDep.minute, 15)
    }

    func testCommuteLegsWithoutAddressesOrGymAreEmpty() {
        let legs = PlanCoordinator.commuteLegs(.init(
            hasGym: true, gymMinute: 19 * 60, events: [],
            locations: [], prepSessions: [], planDate: Date()))
        XCTAssertTrue(legs.isEmpty, "no saved addresses → no legs to price")
    }

    // MARK: Routes API request body (departure clamp + field wiring)

    func testFutureDepartureUpgradesToPredictiveTraffic() throws {
        let now = Date()
        let body = GoogleMapsService.requestBody(origin: "A", destination: "B",
                                                 departure: now.addingTimeInterval(3600), now: now)
        XCTAssertEqual(body["routingPreference"] as? String, "TRAFFIC_AWARE_OPTIMAL")
        let ts = try XCTUnwrap(body["departureTime"] as? String)
        XCTAssertTrue(ts.hasSuffix("Z"), "departureTime must be RFC 3339 UTC, got \(ts)")
    }

    func testNilOrPastDepartureStaysOnLiveTraffic() {
        let now = Date()
        for departure in [nil, now.addingTimeInterval(-3600), now.addingTimeInterval(30)] {
            let body = GoogleMapsService.requestBody(origin: "A", destination: "B", departure: departure, now: now)
            XCTAssertEqual(body["routingPreference"] as? String, "TRAFFIC_AWARE",
                           "past/imminent departure must fall back to live traffic")
            XCTAssertNil(body["departureTime"], "no departureTime may be sent for \(String(describing: departure))")
        }
    }

    // MARK: Departure minute → concrete Date on the plan day

    func testDepartureDateLandsOnPlanDayAtThatMinute() throws {
        let cal = Calendar.current
        let day = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 7, day: 21)))
        let d = try XCTUnwrap(PlanCoordinator.departureDate(minuteOfDay: 13 * 60 + 30, on: day))
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 21)
        XCTAssertEqual(comps.hour, 13)
        XCTAssertEqual(comps.minute, 30)
    }
}
