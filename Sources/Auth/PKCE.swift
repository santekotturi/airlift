import Foundation
import CryptoKit

/// A PKCE (Proof Key for Code Exchange, RFC 7636) verifier/challenge pair.
///
/// Public OAuth clients — like iOS apps — cannot safely hold a client secret, so
/// PKCE binds the authorization request to the token exchange instead.
struct PKCE: Equatable {
    /// High-entropy random string sent (hashed) with the auth request and (raw)
    /// with the token exchange.
    let verifier: String
    /// Base64URL(SHA256(verifier)) — sent as `code_challenge`.
    let challenge: String
    /// Always "S256" here; "plain" is intentionally unsupported.
    let method = "S256"

    init() {
        self.verifier = Self.makeVerifier()
        self.challenge = Self.challenge(for: verifier)
    }

    /// Testable seam: build a pair from a known verifier.
    init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// 32 random bytes → 43-char base64url string (within RFC's 43–128 range).
    private static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64URLEncodedString()
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension Data {
    /// Base64URL without padding, per RFC 7636 §A.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
