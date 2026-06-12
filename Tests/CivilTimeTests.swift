import XCTest
@testable import Airlift

final class CivilTimeTests: XCTestCase {
    func testParsesOffsetBearingISO8601() {
        // 23:14:05 at -07:00 == 06:14:05 UTC the next day.
        let civil = CivilTime(iso8601: "2026-06-07T23:14:05-07:00")
        XCTAssertNotNil(civil)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: civil!.date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 6)
        XCTAssertEqual(parts.day, 8)
        XCTAssertEqual(parts.hour, 6)
        XCTAssertEqual(parts.minute, 14)
        XCTAssertEqual(parts.second, 5)
    }

    func testParsesFractionalSeconds() {
        XCTAssertNotNil(CivilTime(iso8601: "2026-06-07T23:14:05.250-07:00"))
    }

    func testParsesZuluTime() {
        XCTAssertNotNil(CivilTime(iso8601: "2026-06-07T23:14:05Z"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(CivilTime(iso8601: "not-a-date"))
    }

    func testStructuredComponentsRespectOffset() {
        // Same wall clock, different offsets → different absolute instants.
        let pacific = CivilTime(year: 2026, month: 6, day: 7, hour: 23, minute: 0, second: 0, utcOffsetSeconds: -7 * 3600)
        let utc = CivilTime(year: 2026, month: 6, day: 7, hour: 23, minute: 0, second: 0, utcOffsetSeconds: 0)
        XCTAssertNotNil(pacific)
        XCTAssertNotNil(utc)
        XCTAssertEqual(pacific!.date.timeIntervalSince(utc!.date), 7 * 3600, accuracy: 0.5)
    }
}
