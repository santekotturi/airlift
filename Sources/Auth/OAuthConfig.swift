import Foundation

/// Static OAuth configuration for the Google Health API.
///
/// iOS OAuth clients are *public* clients — there is **no client secret**; we use
/// PKCE instead (PRD §6.3). The client ID and reversed client ID are injected at
/// build time from `Config.xcconfig` into `Info.plist`, so the repository stays
/// credential-free and each user brings their own Google Cloud OAuth client.
enum OAuthConfig {
    /// e.g. "1234567890-abcdef.apps.googleusercontent.com"
    static let clientID = infoValue("GHClientID")

    /// Reversed client ID, e.g. "com.googleusercontent.apps.1234567890-abcdef".
    /// Used as the OAuth redirect URL scheme (mirrored in Info.plist URL types).
    static let reversedClientID = infoValue("GHReversedClientID")

    /// Full redirect URI: the reversed client ID scheme plus an `:/oauth` path.
    static var redirectURI: String { "\(reversedClientID):/oauth" }

    /// Custom URL scheme that `ASWebAuthenticationSession` listens for.
    static var callbackScheme: String { reversedClientID }

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// All read-only Google Health scopes. Airlift only *writes* to HealthKit —
    /// it never writes back to Google, so no `.writeonly` scope is ever requested.
    /// Sleep is what v1 syncs; the rest are granted up front so future data types
    /// need no re-consent.
    static let scopes: [String] = [
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
        "https://www.googleapis.com/auth/googlehealth.location.readonly",
        "https://www.googleapis.com/auth/googlehealth.nutrition.readonly",
        "https://www.googleapis.com/auth/googlehealth.profile.readonly",
        "https://www.googleapis.com/auth/googlehealth.irn.readonly",
        "https://www.googleapis.com/auth/googlehealth.ecg.readonly",
    ]

    static var scopeString: String { scopes.joined(separator: " ") }

    /// True once `Config.xcconfig` has been filled in with real values.
    static var isConfigured: Bool {
        !clientID.isEmpty && !reversedClientID.isEmpty
    }

    private static func infoValue(_ key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
