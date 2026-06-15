import XCTest
@testable import Airlift

final class AppInfoTests: XCTestCase {
    func testNewIssueURLTargetsTheRepo() throws {
        let url = try XCTUnwrap(AppInfo.newIssueURL(title: "Hi", body: "Body"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasSuffix("/issues/new"), "path was \(url.path)")
    }

    func testNewIssueURLCarriesTitleBodyAndLabel() throws {
        let url = try XCTUnwrap(AppInfo.newIssueURL(title: "Sleep didn't sync", body: "It broke"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["title"], "Sleep didn't sync")
        XCTAssertEqual(byName["body"], "It broke")
        XCTAssertEqual(byName["labels"], "bug")
    }

    func testNewIssueURLPercentEncodesSpecialCharacters() throws {
        // Markdown/newlines/ampersands must survive into a valid URL.
        let url = try XCTUnwrap(AppInfo.newIssueURL(title: "Crash & burn", body: "Line 1\nLine 2 #42"))
        let raw = url.absoluteString
        XCTAssertFalse(raw.contains("Crash & burn"), "ampersand/spaces must be encoded, not literal")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        // Round-trips back to the original values after decoding.
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "Crash & burn")
        XCTAssertEqual(items.first { $0.name == "body" }?.value, "Line 1\nLine 2 #42")
    }

    func testDiagnosticsBlockHasNoHealthData() {
        let block = AppInfo.diagnosticsBlock
        XCTAssertTrue(block.contains("Airlift"))
        // Only versions/device — never tokens or health values.
        XCTAssertFalse(block.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(block.localizedCaseInsensitiveContains("bpm"))
    }
}
