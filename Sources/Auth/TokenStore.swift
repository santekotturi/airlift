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

    init(service: String = "com.santekotturi.airlift.tokens", account: String = "google-health") {
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
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    func save(_ tokens: StoredTokens) throws {
        let data = try JSONEncoder().encode(tokens)

        // Upsert: try update first, fall back to add.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unhandled(updateStatus)
        }
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
