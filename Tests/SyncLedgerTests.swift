import XCTest
@testable import Airlift

final class SyncLedgerTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-tests-\(UUID().uuidString)")
            .appendingPathComponent("ledger.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    func testSetAndGetRoundTrip() {
        let ledger = FileSyncLedger(url: url)
        ledger.set(.noData, kind: "steps", day: "2026-06-10")
        XCTAssertEqual(ledger.status(kind: "steps", day: "2026-06-10"), .noData)
        XCTAssertNil(ledger.status(kind: "steps", day: "2026-06-11"))
    }

    func testPersistsAcrossInstances() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        FileSyncLedger(url: url).set(.synced(samples: 42, at: date), kind: "sleep", day: "2026-06-11")
        let reloaded = FileSyncLedger(url: url)
        XCTAssertEqual(reloaded.status(kind: "sleep", day: "2026-06-11"), .synced(samples: 42, at: date))
    }

    func testRecordSyncedAccumulatesAcrossRePulls() {
        let ledger = FileSyncLedger(url: url)
        let first = Date(timeIntervalSince1970: 1_750_000_000)
        let second = first.addingTimeInterval(3600)
        ledger.recordSynced(kind: "heart_rate", day: "2026-06-11", samples: 100, at: first)
        ledger.recordSynced(kind: "heart_rate", day: "2026-06-11", samples: 40, at: second)
        XCTAssertEqual(
            ledger.status(kind: "heart_rate", day: "2026-06-11"),
            .synced(samples: 140, at: second)
        )
    }

    func testFillIfEmptyNeverDowngrades() {
        let ledger = FileSyncLedger(url: url)
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        ledger.set(.synced(samples: 7, at: date), kind: "spo2", day: "2026-06-11")
        ledger.fillIfEmpty(.noData, kind: "spo2", day: "2026-06-11")
        XCTAssertEqual(ledger.status(kind: "spo2", day: "2026-06-11"), .synced(samples: 7, at: date))

        ledger.fillIfEmpty(.noData, kind: "spo2", day: "2026-06-12")
        XCTAssertEqual(ledger.status(kind: "spo2", day: "2026-06-12"), .noData)
    }

    func testCivilDayRangeIsInclusiveOldestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 9; components.hour = 13
        let start = calendar.date(from: components)!
        let end = start.addingTimeInterval(2 * 86_400)
        // Formatter uses the current timezone; only assert count + ordering,
        // which hold in any zone.
        let days = CivilDay.days(from: start, through: end, calendar: calendar)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days, days.sorted())
    }

    func testCivilDayRangeEmptyWhenEndPrecedesStart() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertTrue(CivilDay.days(from: start, through: start.addingTimeInterval(-86_400 * 2)).isEmpty)
    }
}

final class SyncGateTests: XCTestCase {
    func testReviewEverythingHoldsEverything() {
        for severity in [CheckResult.Severity.pass, .info, .warn, .fail] {
            XCTAssertEqual(SyncGate.action(for: severity, mode: .reviewEverything), .review)
        }
    }

    func testAutomaticImportsCleanHoldsFlagged() {
        XCTAssertEqual(SyncGate.action(for: .pass, mode: .automatic), .autoImport)
        XCTAssertEqual(SyncGate.action(for: .info, mode: .automatic), .autoImport)
        XCTAssertEqual(SyncGate.action(for: .warn, mode: .automatic), .review)
        XCTAssertEqual(SyncGate.action(for: .fail, mode: .automatic), .review)
    }

    func testHeldStatusSeparatesQuarantineFromPending() {
        XCTAssertEqual(SyncGate.heldStatus(for: .pass), .pendingReview)
        XCTAssertEqual(SyncGate.heldStatus(for: .info), .pendingReview)
        XCTAssertEqual(SyncGate.heldStatus(for: .warn), .quarantined)
        XCTAssertEqual(SyncGate.heldStatus(for: .fail), .quarantined)
    }
}
