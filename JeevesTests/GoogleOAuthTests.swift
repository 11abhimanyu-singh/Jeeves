//
//  GoogleOAuthTests.swift
//  JeevesTests
//
//  Exercises GoogleOAuthService.parseToken against the exact JSON shapes Google's
//  token endpoint (oauth2.googleapis.com/token) returns — a full authorization-code
//  exchange, a refresh response (which omits refresh_token), an error body, and the
//  edge cases that historically break token handling: a missing expires_in, an
//  error with no description, empty {}, and junk. No network, no client ID, no
//  Keychain. Run this instead of round-tripping a real Google sign-in on-device.
//

import XCTest
@testable import Jeeves

final class GoogleOAuthTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    /// A full authorization_code exchange: access_token + expires_in + refresh_token
    /// (plus the scope/token_type fields Google always includes and we ignore).
    func testParsesRealAuthorizationCodeExchange() {
        let token = GoogleOAuthService.parseToken(data("""
        {
          "access_token": "ya29.a0AfB_byC-EXAMPLE-accesstoken",
          "expires_in": 3599,
          "refresh_token": "1//0gEXAMPLE-refreshtoken",
          "scope": "https://www.googleapis.com/auth/calendar.readonly",
          "token_type": "Bearer"
        }
        """))

        XCTAssertEqual(token.accessToken, "ya29.a0AfB_byC-EXAMPLE-accesstoken")
        XCTAssertEqual(token.refreshToken, "1//0gEXAMPLE-refreshtoken")
        XCTAssertEqual(token.expiresIn, 3599)
        XCTAssertNil(token.error, "a successful exchange must not report an error")
    }

    /// A refresh_token grant response: Google returns a fresh access_token and a new
    /// expiry but NO refresh_token (the caller keeps the existing one). The parse must
    /// leave refreshToken nil so the caller doesn't clobber the stored token.
    func testRefreshResponseHasNoRefreshToken() {
        let token = GoogleOAuthService.parseToken(data("""
        {
          "access_token": "ya29.a0AfB_byC-REFRESHED",
          "expires_in": 3599,
          "scope": "https://www.googleapis.com/auth/calendar.readonly",
          "token_type": "Bearer"
        }
        """))

        XCTAssertEqual(token.accessToken, "ya29.a0AfB_byC-REFRESHED")
        XCTAssertEqual(token.expiresIn, 3599)
        XCTAssertNil(token.refreshToken, "a refresh response omits refresh_token")
        XCTAssertNil(token.error)
    }

    /// The classic failure: a revoked/expired refresh token. Google returns
    /// {"error","error_description"} with no tokens. parseToken must surface the
    /// human-readable error_description (preferred over the machine `error` code)
    /// and leave every token field nil so the caller throws tokenExchangeFailed.
    func testErrorBodyPrefersErrorDescription() {
        let token = GoogleOAuthService.parseToken(data("""
        { "error": "invalid_grant",
          "error_description": "Token has been expired or revoked." }
        """))

        XCTAssertNil(token.accessToken)
        XCTAssertNil(token.refreshToken)
        XCTAssertNil(token.expiresIn)
        XCTAssertEqual(token.error, "Token has been expired or revoked.")
    }

    /// Some token errors carry only the machine `error` code and no description —
    /// parseToken must fall back to it rather than returning a nil message.
    func testErrorBodyFallsBackToErrorCode() {
        let token = GoogleOAuthService.parseToken(data("""
        { "error": "invalid_grant" }
        """))

        XCTAssertNil(token.accessToken)
        XCTAssertEqual(token.error, "invalid_grant")
    }

    /// A token body that omits expires_in is incomplete: the caller's guard requires
    /// both access_token AND expires_in, so a nil expiry means the exchange fails even
    /// though an access_token is present. Pin that expiresIn stays nil here.
    func testTokenMissingExpiresInIsIncomplete() {
        let token = GoogleOAuthService.parseToken(data("""
        { "access_token": "ya29.a0AfB_byC-NOEXPIRY", "token_type": "Bearer" }
        """))

        XCTAssertEqual(token.accessToken, "ya29.a0AfB_byC-NOEXPIRY")
        XCTAssertNil(token.expiresIn, "no expires_in must not be invented")
        XCTAssertNil(token.error)
    }

    /// Empty object and non-JSON junk must both parse to an all-nil result (no crash,
    /// no throw) — the caller then treats it as a failed exchange.
    func testEmptyAndJunkReturnAllNil() {
        let empty = GoogleOAuthService.parseToken(data("{}"))
        XCTAssertEqual(empty, GoogleTokenResponse(accessToken: nil, refreshToken: nil,
                                                  expiresIn: nil, error: nil))

        let junk = GoogleOAuthService.parseToken(data("not a json body {"))
        XCTAssertEqual(junk, GoogleTokenResponse(accessToken: nil, refreshToken: nil,
                                                 expiresIn: nil, error: nil))

        let blank = GoogleOAuthService.parseToken(Data())
        XCTAssertNil(blank.accessToken)
        XCTAssertNil(blank.expiresIn)
        XCTAssertNil(blank.error)
    }
}
