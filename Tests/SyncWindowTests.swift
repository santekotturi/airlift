import XCTest
@testable import AirKit

final class SyncWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000) // fixed reference
    private let day: TimeInterval = 86_400

    func testFirstRunLooksBackSevenDays() {
        let since = SyncWindow.fetchSince(lastSynced: nil, now: now)
        XCTAssertEqual(since, now.addingTimeInterval(-7 * day))
    }

    func testRecentLastSyncRePullsLastTwoDays() {
        // Synced an hour ago → still re-pull the last 2 days for late edits.
        let lastSynced = now.addingTimeInterval(-3600)
        let since = SyncWindow.fetchSince(lastSynced: lastSynced, now: now)
        XCTAssertEqual(since, now.addingTimeInterval(-2 * day))
    }

    func testOldLastSyncFetchesFromLastSync() {
        // Gap larger than the re-pull floor → fetch from where we left off.
        let lastSynced = now.addingTimeInterval(-10 * day)
        let since = SyncWindow.fetchSince(lastSynced: lastSynced, now: now)
        XCTAssertEqual(since, lastSynced)
    }

    func testCustomLookbackAndRePull() {
        let since = SyncWindow.fetchSince(
            lastSynced: nil, now: now, firstRunLookbackDays: 30, rePullDays: 1
        )
        XCTAssertEqual(since, now.addingTimeInterval(-30 * day))
    }
}
