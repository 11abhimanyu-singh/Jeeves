//
//  KeychainService.swift
//  Jeeves
//
//  Minimal Keychain wrapper for the user's own API keys (Anthropic, Google
//  Books), entered in the Library's Settings sheet. Never hardcoded, never
//  leave the device except in direct HTTPS calls to their respective APIs.
//

import Foundation
import Security

enum KeychainService {
    private static let service = "com.abhimanyusingh.Jeeves"

    private static func save(_ key: String, account: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Anthropic (shelf scanning, book summaries)

    private static let anthropicAccount = "anthropicAPIKey"

    static func saveAPIKey(_ key: String) { save(key, account: anthropicAccount) }
    static func loadAPIKey() -> String? { load(account: anthropicAccount) }
    static func deleteAPIKey() { delete(account: anthropicAccount) }
    static var hasAPIKey: Bool { !(loadAPIKey() ?? "").isEmpty }

    // MARK: Google Books (ISBN/cover fallback when Open Library has no match)

    private static let googleBooksAccount = "googleBooksAPIKey"

    static func saveGoogleBooksAPIKey(_ key: String) { save(key, account: googleBooksAccount) }
    static func loadGoogleBooksAPIKey() -> String? { load(account: googleBooksAccount) }
    static func deleteGoogleBooksAPIKey() { delete(account: googleBooksAccount) }
    static var hasGoogleBooksAPIKey: Bool { !(loadGoogleBooksAPIKey() ?? "").isEmpty }

    // MARK: Google Maps (real commute times with live traffic)

    private static let googleMapsAccount = "googleMapsAPIKey"

    static func saveGoogleMapsAPIKey(_ key: String) { save(key, account: googleMapsAccount) }
    static func loadGoogleMapsAPIKey() -> String? { load(account: googleMapsAccount) }
    static func deleteGoogleMapsAPIKey() { delete(account: googleMapsAccount) }
    static var hasGoogleMapsAPIKey: Bool { !(loadGoogleMapsAPIKey() ?? "").isEmpty }

    // MARK: Google Calendar OAuth (iOS OAuth client ID + tokens)

    private static let googleClientIDAccount = "googleOAuthClientID"
    private static let googleAccessTokenAccount = "googleAccessToken"
    private static let googleRefreshTokenAccount = "googleRefreshToken"
    private static let googleTokenExpiryAccount = "googleTokenExpiry"  // epoch seconds as string

    static func saveGoogleClientID(_ id: String) { save(id, account: googleClientIDAccount) }
    static func loadGoogleClientID() -> String? { load(account: googleClientIDAccount) }
    static func deleteGoogleClientID() { delete(account: googleClientIDAccount) }
    static var hasGoogleClientID: Bool { !(loadGoogleClientID() ?? "").isEmpty }

    static func saveGoogleTokens(access: String, refresh: String?, expiry: Date) {
        save(access, account: googleAccessTokenAccount)
        if let refresh { save(refresh, account: googleRefreshTokenAccount) }
        save(String(expiry.timeIntervalSince1970), account: googleTokenExpiryAccount)
    }
    static func loadGoogleAccessToken() -> String? { load(account: googleAccessTokenAccount) }
    static func loadGoogleRefreshToken() -> String? { load(account: googleRefreshTokenAccount) }
    static func loadGoogleTokenExpiry() -> Date? {
        load(account: googleTokenExpiryAccount).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }
    static func updateGoogleAccessToken(_ access: String, expiry: Date) {
        save(access, account: googleAccessTokenAccount)
        save(String(expiry.timeIntervalSince1970), account: googleTokenExpiryAccount)
    }
    static func deleteGoogleTokens() {
        delete(account: googleAccessTokenAccount)
        delete(account: googleRefreshTokenAccount)
        delete(account: googleTokenExpiryAccount)
    }
    static var isGoogleCalendarConnected: Bool { loadGoogleRefreshToken() != nil }
}
