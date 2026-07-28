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

    private func blk(_ title: String, _ start: String, _ end: String, kind: String = "activity") -> GeneratedBlock {
        GeneratedBlock(title: title, startTime: start, endTime: end, note: nil, isAnchor: false, kind: kind)
    }

    // MARK: Mid-day re-plan — which blocks are preserved

    func testLockedBlocksArePreciselyThoseFullyElapsed() {
        let plan = GeneratedPlan(blocks: [
            blk("Morning shower", "09:36", "09:56"),
            blk("Massage", "10:30", "13:00", kind: "event"),
            blk("Lunch", "13:00", "13:30", kind: "lunch"),
            blk("Reading", "13:30", "14:30"),                 // ends after cutoff → not locked
            blk("Sleep", "23:00", "07:00", kind: "sleep"),    // wraps midnight → never locked
        ], dropped: [], shrunk: [], summary: "", boundaryTime: nil)

        let locked = PlanCoordinator.lockedBlocks(plan, endedBy: 14 * 60) // 14:00
        XCTAssertEqual(locked.map(\.title), ["Morning shower", "Massage", "Lunch"],
                       "only blocks fully ended by 14:00, excluding the wrap-around Sleep")
    }

    func testLockedBlocksEmptyEarlyInDay() {
        let plan = GeneratedPlan(blocks: [blk("Reading", "08:00", "09:30")],
                                 dropped: [], shrunk: [], summary: "", boundaryTime: nil)
        XCTAssertTrue(PlanCoordinator.lockedBlocks(plan, endedBy: 7 * 60).isEmpty,
                      "nothing has elapsed at 07:00")
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
        let body = GoogleMapsService.requestBody(origin: .address("A"), destination: .address("B"),
                                                 departure: now.addingTimeInterval(3600), now: now)
        XCTAssertEqual(body["routingPreference"] as? String, "TRAFFIC_AWARE_OPTIMAL")
        let ts = try XCTUnwrap(body["departureTime"] as? String)
        XCTAssertTrue(ts.hasSuffix("Z"), "departureTime must be RFC 3339 UTC, got \(ts)")
    }

    func testNilOrPastDepartureStaysOnLiveTraffic() {
        let now = Date()
        for departure in [nil, now.addingTimeInterval(-3600), now.addingTimeInterval(30)] {
            let body = GoogleMapsService.requestBody(origin: .address("A"), destination: .address("B"), departure: departure, now: now)
            XCTAssertEqual(body["routingPreference"] as? String, "TRAFFIC_AWARE",
                           "past/imminent departure must fall back to live traffic")
            XCTAssertNil(body["departureTime"], "no departureTime may be sent for \(String(describing: departure))")
        }
    }

    // MARK: Maps-link resolution (pure)

    func testCoordinateWaypointBuildsLatLngJSON() {
        let json = GoogleMapsService.Waypoint.location(lat: 12.97, lng: 77.59).requestJSON
        let latLng = (json["location"] as? [String: Any])?["latLng"] as? [String: Any]
        XCTAssertEqual(latLng?["latitude"] as? Double, 12.97)
        XCTAssertEqual(latLng?["longitude"] as? Double, 77.59)
    }

    func testAddressWaypointBuildsAddressJSON() {
        XCTAssertEqual(GoogleMapsService.Waypoint.address("MLR, Bengaluru").requestJSON["address"] as? String,
                       "MLR, Bengaluru")
    }

    func testIsMapsLinkDetectsShareLinksNotPlainAddresses() {
        XCTAssertTrue(GoogleMapsService.isMapsLink("https://maps.app.goo.gl/tUVY5KumZEco"))
        XCTAssertTrue(GoogleMapsService.isMapsLink("https://goo.gl/maps/abc123"))
        XCTAssertTrue(GoogleMapsService.isMapsLink("https://www.google.com/maps/place/Foo"))
        XCTAssertFalse(GoogleMapsService.isMapsLink("MLR Convention Centre, Bengaluru"))
        XCTAssertFalse(GoogleMapsService.isMapsLink("12.97,77.59"))
        XCTAssertFalse(GoogleMapsService.isMapsLink("https://example.com/not-maps"))
    }

    func testExtractCoordinatesPrefersPlacePinOverViewportCentre() {
        // Real maps URL shape: @ is the viewport centre (12.9716…), the actual
        // place pin is in !3d…!4d… (12.9721…) — we must pick the pin.
        let url = "https://www.google.com/maps/place/Clinic/@12.9716,77.5946,17z/data=!3m1!4b1!4m6!3m5!8m2!3d12.9721!4d77.5951"
        let c = GoogleMapsService.extractCoordinates(fromText: url)
        XCTAssertEqual(c?.lat, 12.9721)
        XCTAssertEqual(c?.lng, 77.5951)
    }

    func testExtractCoordinatesFromQueryParam() {
        let c = GoogleMapsService.extractCoordinates(fromText: "https://maps.google.com/?q=40.7128,-74.0060")
        XCTAssertEqual(c?.lat, 40.7128)
        XCTAssertEqual(c?.lng, -74.0060)
    }

    func testExtractCoordinatesFallsBackToViewportCentre() {
        let c = GoogleMapsService.extractCoordinates(fromText: "https://www.google.com/maps/@48.8584,2.2945,15z")
        XCTAssertEqual(c?.lat, 48.8584)
        XCTAssertEqual(c?.lng, 2.2945)
    }

    func testExtractCoordinatesRejectsOutOfRangeAndMissing() {
        XCTAssertNil(GoogleMapsService.extractCoordinates(fromText: "no coordinates here"))
        XCTAssertNil(GoogleMapsService.extractCoordinates(fromText: "@200.0,999.0"), "impossible earth coords are rejected")
    }

    func testPlaceNameFromExpandedShareLinkURL() {
        // The exact URL a maps.app.goo.gl/… link expands to — name in the /place/
        // path, pin in !3d…!4d… (12.9351856 / 77.6245997), viewport centre in @.
        let url = "https://www.google.com/maps/place/BlueStone+Jewellery+Koramangala/@12.9351856,77.6220248,971m/data=!3m2!1e3!4b1!4m6!3m5!8m2!3d12.9351856!4d77.6245997"
        XCTAssertEqual(GoogleMapsService.placeName(fromText: url), "BlueStone Jewellery Koramangala")
        let c = GoogleMapsService.extractCoordinates(fromText: url)
        XCTAssertEqual(c?.lat, 12.9351856)
        XCTAssertEqual(c?.lng, 77.6245997)
    }

    func testPlaceNamePercentDecodesAndStopsBeforeCoords() {
        let url = "https://www.google.com/maps/place/Caf%C3%A9+Noir/@40.0,-74.0,15z"
        XCTAssertEqual(GoogleMapsService.placeName(fromText: url), "Café Noir")
    }

    func testPlaceNameNilWhenNoPlaceSegment() {
        XCTAssertNil(GoogleMapsService.placeName(fromText: "https://www.google.com/maps/@48.8584,2.2945,15z"))
        XCTAssertNil(GoogleMapsService.placeName(fromText: "MLR Convention Centre, Bengaluru"))
    }

    /// A long maps URL that already carries the name resolves with no network.
    func testResolvePlaceFromFullURLNeedsNoNetwork() async {
        let url = "https://www.google.com/maps/place/BlueStone+Jewellery+Koramangala/@12.9351856,77.6220248,971m/data=!4m6!3m5!8m2!3d12.9351856!4d77.6245997"
        let place = await GoogleMapsService.resolvePlace(url)
        XCTAssertEqual(place?.name, "BlueStone Jewellery Koramangala")
        XCTAssertEqual(place?.lat, 12.9351856)
        XCTAssertEqual(place?.lng, 77.6245997)
    }

    func testResolvePlaceNilForPlainAddress() async {
        let place = await GoogleMapsService.resolvePlace("MLR Convention Centre, Bengaluru")
        XCTAssertNil(place)
    }

    /// A plain address must resolve to an .address waypoint without any network.
    func testResolveWaypointPassesPlainAddressThrough() async {
        let wp = await GoogleMapsService.resolveWaypoint("MLR Convention Centre, Bengaluru")
        XCTAssertEqual(wp, .address("MLR Convention Centre, Bengaluru"))
    }

    /// A long maps URL with embedded coordinates resolves offline (no redirect).
    func testResolveWaypointExtractsFromLongURLWithoutNetwork() async {
        let wp = await GoogleMapsService.resolveWaypoint("https://www.google.com/maps/place/X/@1.0,2.0,17z/data=!3d3.5!4d4.5")
        XCTAssertEqual(wp, .location(lat: 3.5, lng: 4.5))
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
