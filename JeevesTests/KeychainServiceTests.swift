//
//  KeychainServiceTests.swift
//  JeevesTests
//
//  Round-trips every key type through the real (Simulator) Keychain. Backs
//  up and restores whatever's already stored so running the suite never
//  wipes keys the app is actually using.
//

import XCTest
@testable import Jeeves

final class KeychainServiceTests: XCTestCase {

    private var savedAnthropic: String?
    private var savedMaps: String?
    private var savedBooks: String?
    private var savedClientID: String?

    override func setUp() {
        savedAnthropic = KeychainService.loadAPIKey()
        savedMaps = KeychainService.loadGoogleMapsAPIKey()
        savedBooks = KeychainService.loadGoogleBooksAPIKey()
        savedClientID = KeychainService.loadGoogleClientID()
    }

    override func tearDown() {
        restore(savedAnthropic, KeychainService.saveAPIKey, KeychainService.deleteAPIKey)
        restore(savedMaps, KeychainService.saveGoogleMapsAPIKey, KeychainService.deleteGoogleMapsAPIKey)
        restore(savedBooks, KeychainService.saveGoogleBooksAPIKey, KeychainService.deleteGoogleBooksAPIKey)
        restore(savedClientID, KeychainService.saveGoogleClientID, KeychainService.deleteGoogleClientID)
    }

    private func restore(_ value: String?, _ save: (String) -> Void, _ delete: () -> Void) {
        if let value { save(value) } else { delete() }
    }

    func testAnthropicRoundTrip() {
        KeychainService.saveAPIKey("test-anthropic-123")
        XCTAssertEqual(KeychainService.loadAPIKey(), "test-anthropic-123")
        XCTAssertTrue(KeychainService.hasAPIKey)
        KeychainService.deleteAPIKey()
        XCTAssertNil(KeychainService.loadAPIKey())
        XCTAssertFalse(KeychainService.hasAPIKey)
    }

    func testKeysAreIndependent() {
        KeychainService.saveGoogleMapsAPIKey("maps-key")
        KeychainService.saveGoogleBooksAPIKey("books-key")
        XCTAssertEqual(KeychainService.loadGoogleMapsAPIKey(), "maps-key")
        XCTAssertEqual(KeychainService.loadGoogleBooksAPIKey(), "books-key")
        // Deleting one must not touch the other.
        KeychainService.deleteGoogleMapsAPIKey()
        XCTAssertNil(KeychainService.loadGoogleMapsAPIKey())
        XCTAssertEqual(KeychainService.loadGoogleBooksAPIKey(), "books-key")
    }

    func testOverwriteReplacesValue() {
        KeychainService.saveGoogleClientID("first")
        KeychainService.saveGoogleClientID("second")
        XCTAssertEqual(KeychainService.loadGoogleClientID(), "second")
    }

    func testCalendarConnectedReflectsRefreshToken() {
        KeychainService.deleteGoogleTokens()
        XCTAssertFalse(KeychainService.isGoogleCalendarConnected)
        KeychainService.saveGoogleTokens(access: "a", refresh: "r", expiry: Date().addingTimeInterval(3600))
        XCTAssertTrue(KeychainService.isGoogleCalendarConnected)
        XCTAssertEqual(KeychainService.loadGoogleAccessToken(), "a")
        KeychainService.deleteGoogleTokens()
        XCTAssertFalse(KeychainService.isGoogleCalendarConnected)
    }
}
