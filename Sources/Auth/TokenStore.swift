import Foundation
import Security

/// OAuth token material persisted between launches.
struct StoredTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Absolute time the access token stops being valid (access tokens live ~1h).
    var accessTokenExpiry: Date
    var scope: String?

    /// Treat the token as expired a little early to avoid racing the boundary.
    func isAccessTokenValid(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) < accessTokenExpiry
    }
}

/// Persists `StoredTokens` in the Keychain.
///
/// The refresh token is the long-lived credential and must never touch
/// `UserDefaults`/plist storage — keychain only, locked to this device.
protocol TokenStoring: Sendable {
    func load() -> StoredTokens?
    func save(_ tokens: StoredTokens) throws
    func clear() throws
}

struct KeychainTokenStore: TokenStoring {
    private let service: String
    private let account: String

    init(
        service: String = "\(Bundle.main.bundleIdentifier ?? "airlift").tokens",
        account: String = "google-health"
    ) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> StoredTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Log.auth.error("Keychain load failed: \(status)")
            }
            return nil
        }
        guard let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data) else {
            // An undecodable item is unrecoverable garbage — clear it so the
            // app offers a fresh sign-in instead of failing forever.
            Log.auth.error("Stored token data was undecodable — clearing the keychain item")
            try? clear()
            return nil
        }
        return tokens
    }

    func save(_ tokens: StoredTokens) throws {
        let data = try JSONEncoder().encode(tokens)

        // Delete-then-add: SecItemUpdate cannot change the accessibility class
        // of an existing item, and a token save is rare enough that upsert
        // performance doesn't matter.
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        // ThisDeviceOnly: the refresh token must not migrate via device
        // backups or transfers. AfterFirstUnlock (not WhenUnlocked) so the
        // background refresh task can read it on a locked phone.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}

enum KeychainError: Error, LocalizedError {
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        }
    }
}
