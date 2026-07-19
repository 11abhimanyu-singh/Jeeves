//
//  GoogleOAuthService.swift
//  Jeeves
//
//  Google OAuth 2.0 for native iOS with PKCE (PRD §5.5.1, §7 secrets). Uses
//  ASWebAuthenticationSession, which intercepts the redirect in-process —
//  so no CFBundleURLTypes registration in Info.plist is needed. The iOS
//  OAuth client has no client secret (public client); PKCE secures the
//  exchange. Tokens live in Keychain; the client ID is user-supplied.
//
//  Requires a Google Cloud "iOS" OAuth client ID for this app's bundle id
//  (abhimanyusingh.me.Jeeves), with the Google Calendar API enabled and the
//  calendar.readonly scope on the consent screen.
//

import Foundation
import AuthenticationServices
import CryptoKit

enum GoogleOAuthError: LocalizedError {
    case missingClientID
    case notConnected
    case authFailed(String)
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: return "Add your Google OAuth client ID in Settings first."
        case .notConnected: return "Connect your Google account in Plan setup first."
        case .authFailed(let m): return "Google sign-in failed: \(m)"
        case .tokenExchangeFailed(let m): return "Couldn't complete Google sign-in: \(m)"
        }
    }
}

@MainActor
final class GoogleOAuthService: NSObject {
    static let shared = GoogleOAuthService()

    private let scope = "https://www.googleapis.com/auth/calendar.readonly"
    private let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenEndpoint = "https://oauth2.googleapis.com/token"

    /// Full interactive sign-in: opens Google, gets an auth code, exchanges it
    /// for tokens, and stores them. Must be called from the UI (main actor).
    func connect() async throws {
        guard let clientID = KeychainService.loadGoogleClientID(), !clientID.isEmpty else {
            throw GoogleOAuthError.missingClientID
        }
        let scheme = reversedScheme(for: clientID)
        let redirectURI = "\(scheme):/oauth2redirect"

        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(for: verifier)

        var comps = URLComponents(string: authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),   // needed for a refresh token
            .init(name: "prompt", value: "consent"),
        ]
        guard let authURL = comps.url else { throw GoogleOAuthError.authFailed("bad auth URL") }

        let callbackURL = try await authenticate(url: authURL, scheme: scheme)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GoogleOAuthError.authFailed("no authorization code returned")
        }

        try await exchangeCode(code, clientID: clientID, redirectURI: redirectURI, verifier: verifier)
    }

    /// Returns a currently-valid access token, refreshing it if expired.
    func validAccessToken() async throws -> String {
        guard KeychainService.isGoogleCalendarConnected,
              let refresh = KeychainService.loadGoogleRefreshToken(),
              let clientID = KeychainService.loadGoogleClientID() else {
            throw GoogleOAuthError.notConnected
        }
        if let token = KeychainService.loadGoogleAccessToken(),
           let expiry = KeychainService.loadGoogleTokenExpiry(),
           expiry.timeIntervalSinceNow > 60 {
            return token
        }
        // Expired (or near it) — refresh.
        return try await refreshAccessToken(refresh: refresh, clientID: clientID)
    }

    func disconnect() {
        KeychainService.deleteGoogleTokens()
    }

    // MARK: Token calls

    private func exchangeCode(_ code: String, clientID: String, redirectURI: String, verifier: String) async throws {
        let params = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        let json = try await postForm(params)
        guard let access = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            throw GoogleOAuthError.tokenExchangeFailed(errorMessage(json) ?? "no access token")
        }
        let refresh = json["refresh_token"] as? String
        KeychainService.saveGoogleTokens(access: access, refresh: refresh, expiry: Date().addingTimeInterval(expiresIn))
    }

    private func refreshAccessToken(refresh: String, clientID: String) async throws -> String {
        let params = [
            "client_id": clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ]
        let json = try await postForm(params)
        guard let access = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            throw GoogleOAuthError.tokenExchangeFailed(errorMessage(json) ?? "refresh failed")
        }
        KeychainService.updateGoogleAccessToken(access, expiry: Date().addingTimeInterval(expiresIn))
        return access
    }

    private func postForm(_ params: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func errorMessage(_ json: [String: Any]) -> String? {
        (json["error_description"] as? String) ?? (json["error"] as? String)
    }

    // MARK: ASWebAuthenticationSession

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: GoogleOAuthError.authFailed(error?.localizedDescription ?? "cancelled"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    // MARK: PKCE

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }

    private func reversedScheme(for clientID: String) -> String {
        // "1234-abc.apps.googleusercontent.com" -> "com.googleusercontent.apps.1234-abc"
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix)"
    }
}

extension GoogleOAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
