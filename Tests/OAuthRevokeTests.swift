import XCTest
@testable import Airlift

final class OAuthRevokeTests: XCTestCase {
    func testRevokeRequestPostsFormEncodedTokenToGoogle() throws {
        let request = OAuthClient.revokeRequest(token: "1//refresh+token/with=chars")
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(body, "token=1%2F%2Frefresh%2Btoken%2Fwith%3Dchars")
    }

    func testSuccessCountsAsRevoked() {
        XCTAssertTrue(OAuthClient.isRevoked(status: 200, body: ""))
    }

    func testAlreadyInvalidTokenCountsAsRevoked() {
        let body = #"{"error": "invalid_token", "error_description": "Token expired or revoked"}"#
        XCTAssertTrue(OAuthClient.isRevoked(status: 400, body: body))
    }

    func testOtherFailuresAreNotRevoked() {
        XCTAssertFalse(OAuthClient.isRevoked(status: 400, body: #"{"error": "invalid_request"}"#))
        XCTAssertFalse(OAuthClient.isRevoked(status: 503, body: ""))
        XCTAssertFalse(OAuthClient.isRevoked(status: -1, body: ""))
    }
}
