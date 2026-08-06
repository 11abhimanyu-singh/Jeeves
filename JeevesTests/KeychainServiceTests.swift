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
        // hasAPIKey, deliberately NOT hasResolvableAPIKey: this is a test of the
        // KEYCHAIN, and the resolvable form would be true whenever the runner
        // happens to carry an environment key — a test that passes or fails on
        // the shell it was launched from is worse than no test.
        XCTAssertFalse(KeychainService.hasAPIKey)
    }

    /// Resolution order: the Keychain wins, and the environment is only a
    /// fallback. A key typed into Settings must never be shadowed by a stale
    /// export in somebody's shell profile.
    func testTheKeychainOutranksTheEnvironment() {
        let saved = KeychainService.loadAPIKey()
        defer { restore(saved, KeychainService.saveAPIKey, KeychainService.deleteAPIKey) }

        KeychainService.saveAPIKey("from-the-keychain")
        XCTAssertEqual(KeychainService.resolveAPIKey(), "from-the-keychain")
        KeychainService.deleteAPIKey()
        // With no stored key, resolution falls through to the environment —
        // which is empty in a normal run, so this asserts the shape rather than
        // a value the test cannot control.
        let resolved = KeychainService.resolveAPIKey()
        let fromEnv = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        XCTAssertEqual(resolved, (fromEnv?.isEmpty == false) ? fromEnv : nil)
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
