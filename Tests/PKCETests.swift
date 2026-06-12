import XCTest
@testable import Airlift

final class PKCETests: XCTestCase {
    /// Canonical test vector from RFC 7636 §B.
    func testKnownVectorProducesExpectedChallenge() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(PKCE.challenge(for: verifier), expected)
    }

    func testGeneratedVerifierIsURLSafeAndCorrectLength() {
        let pkce = PKCE()
        // 32 random bytes → 43 base64url chars, no padding.
        XCTAssertEqual(pkce.verifier.count, 43)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertFalse(pkce.verifier.contains("="))
    }

    func testChallengeIsDeterministicForSameVerifier() {
        let pkce = PKCE(verifier: "constant-verifier-value-for-the-test-1234567")
        XCTAssertEqual(pkce.challenge, PKCE.challenge(for: pkce.verifier))
    }

    func testTwoGeneratedVerifiersDiffer() {
        XCTAssertNotEqual(PKCE().verifier, PKCE().verifier)
    }
}
