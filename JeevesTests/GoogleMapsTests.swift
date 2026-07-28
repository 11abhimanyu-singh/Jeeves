//
//  GoogleMapsTests.swift
//  JeevesTests
//
//  Exercises GoogleMapsService.parseMinutes against real Routes-API
//  (computeRoutes) response shapes — a duration string like "2491s" mapped to
//  rounded driving minutes — plus the edge cases that historically fall back to
//  the default commute: empty routes, a missing duration, an API error body,
//  and junk. No network, no key. Run this instead of round-tripping the phone.
//

import XCTest
@testable import Jeeves

final class GoogleMapsTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    /// The exact shape computeRoutes returns under the "routes.duration" field
    /// mask: a `routes` array whose first entry's `duration` is a seconds string.
    func testParsesDurationToRoundedMinutes() {
        // 2491s = 41.516… min → rounds to 42.
        XCTAssertEqual(GoogleMapsService.parseMinutes(data("""
        { "routes": [ { "duration": "2491s" } ] }
        """)), 42)

        // 600s = exactly 10 min.
        XCTAssertEqual(GoogleMapsService.parseMinutes(data("""
        { "routes": [ { "duration": "600s" } ] }
        """)), 10)
    }

    /// Small/edge durations still round to a sensible whole minute.
    func testSmallAndFractionalDurations() {
        // 89s = 1.483… min → rounds to 1.
        XCTAssertEqual(GoogleMapsService.parseMinutes(data("""
        { "routes": [ { "duration": "89s" } ] }
        """)), 1)

        // 29s = 0.483… min → rounds down to 0 (a very short leg, not nil).
        XCTAssertEqual(GoogleMapsService.parseMinutes(data("""
        { "routes": [ { "duration": "29s" } ] }
        """)), 0)

        // Routes can return a fractional-seconds duration: 150.5s = 2.508… → 3.
        XCTAssertEqual(GoogleMapsService.parseMinutes(data("""
        { "routes": [ { "duration": "150.5s" } ] }
        """)), 3)
    }

    /// Multiple candidate routes come back; we price the leg off the first one.
    func testUsesFirstRouteWhenSeveralReturned() {
        XCTAssertEqual(GoogleMapsService.parseMinutes(data("""
        { "routes": [ { "duration": "2491s" }, { "duration": "3000s" } ] }
        """)), 42)
    }

    /// An unroutable origin/destination comes back as a 200 with no routes.
    func testEmptyRoutesIsNil() {
        XCTAssertNil(GoogleMapsService.parseMinutes(data("""
        { "routes": [] }
        """)))
    }

    /// A route object with no `duration` field must not crash or fabricate 0.
    func testMissingDurationIsNil() {
        XCTAssertNil(GoogleMapsService.parseMinutes(data("""
        { "routes": [ { } ] }
        """)))
    }

    /// The API's error envelope (no `routes` key) parses to nil, not a throw.
    func testApiErrorBodyIsNil() {
        XCTAssertNil(GoogleMapsService.parseMinutes(data("""
        { "error": { "code": 400, "message": "Request contains an invalid argument.",
                     "status": "INVALID_ARGUMENT" } }
        """)))
    }

    /// Non-numeric / malformed duration and outright junk both yield nil.
    func testMalformedDurationAndJunkAreNil() {
        XCTAssertNil(GoogleMapsService.parseMinutes(data("""
        { "routes": [ { "duration": "banana" } ] }
        """)))
        XCTAssertNil(GoogleMapsService.parseMinutes(data("not json")))
        XCTAssertNil(GoogleMapsService.parseMinutes(Data()))
    }
}
