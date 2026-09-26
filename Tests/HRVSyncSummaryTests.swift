import XCTest
@testable import Airlift

/// The morning notification the "Sync New Data" shortcut posts.
final class HRVSyncSummaryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// Saturday 26 Sep 2026, 7am Pacific.
    private let morning = Date(timeIntervalSince1970: 1_790_431_200)

    private func batch(
        day: Date,
        fitbit: [Double],
        apple: [Double] = [],
        appleIsRMSSD: Bool = true,
        hardware: String? = "Watch8,1",
        checks: [CheckResult] = []
    ) -> StagedMetricBatch {
        StagedMetricBatch(
            kind: .heartRateVariability,
            day: day,
            samples: fitbit.enumerated().map { index, value in
                MetricSample(id: "p\(index)", start: day, end: day, value: value)
            },
            appleSamples: apple.map { value in
                QuantitySample(id: UUID(), start: day, end: day, value: value, hardware: hardware)
            },
            checks: checks,
            appleIsRMSSD: appleIsRMSSD
        )
    }

    private var today: Date { calendar.startOfDay(for: morning) }

    func testImportedNightNamesBothDevicesAndStatistics() {
        let summary = HRVSyncSummary.make(
            batch: batch(day: today, fitbit: [50, 56], apple: [60, 70]),
            outcome: .imported, fitbitName: "Google Fitbit Air", calendar: calendar, now: morning
        )
        XCTAssertEqual(summary.title, "Last night's HRV is in Apple Health")
        XCTAssertEqual(summary.body, "Google Fitbit Air: 53 ms across 2 readings. Watch Ultra 4 RMSSD: 65 ms.")
    }

    func testAnUltra2NightSaysSDNN() {
        let summary = HRVSyncSummary.make(
            batch: batch(day: today, fitbit: [50], apple: [90], appleIsRMSSD: false, hardware: "Watch7,5"),
            outcome: .imported, fitbitName: "Google Fitbit Air", calendar: calendar, now: morning
        )
        XCTAssertTrue(summary.body.hasSuffix("Watch Ultra 2 SDNN: 90 ms."))
    }

    func testANightWithoutTheWatchSaysSo() {
        let summary = HRVSyncSummary.make(
            batch: batch(day: today, fitbit: [50]),
            outcome: .imported, fitbitName: "Fitbit", calendar: calendar, now: morning
        )
        XCTAssertTrue(summary.body.hasSuffix("No Apple Watch HRV for that night."))
    }

    func testAHeldNightSaysWhy() {
        let summary = HRVSyncSummary.make(
            batch: batch(
                day: today, fitbit: [50],
                checks: [CheckResult(name: "Range", severity: .warn, detail: "3 readings above 300 ms")]
            ),
            outcome: .held, fitbitName: "Fitbit", calendar: calendar, now: morning
        )
        XCTAssertEqual(summary.title, "Last night's HRV is waiting for you")
        XCTAssertTrue(summary.body.contains("held back: 3 readings above 300 ms"))
    }

    func testReviewModeAsksForATap() {
        let summary = HRVSyncSummary.make(
            batch: batch(day: today, fitbit: [50]),
            outcome: .awaitingReview, fitbitName: "Fitbit", calendar: calendar, now: morning
        )
        XCTAssertEqual(summary.title, "Last night's HRV is ready to review")
    }

    /// An older night is named by the evening it started.
    func testAnOlderNightIsNamedByItsEvening() throws {
        let fridayMorning = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let summary = HRVSyncSummary.make(
            batch: batch(day: fridayMorning, fitbit: [50]),
            outcome: .imported, fitbitName: "Fitbit", calendar: calendar, now: morning
        )
        XCTAssertEqual(summary.title, "Thursday night's HRV is in Apple Health")
    }

    func testNothingNewPointsAtTheBandUpload() {
        let summary = HRVSyncSummary.make(
            batch: nil, outcome: .imported, fitbitName: "Fitbit", calendar: calendar, now: morning
        )
        XCTAssertEqual(summary.title, "No new HRV from Fitbit")
        XCTAssertTrue(summary.body.contains("open Google Health"))
    }

    func testFailureCarriesTheMessage() {
        let summary = HRVSyncSummary.make(
            batch: nil, outcome: .failed("The network connection was lost."), fitbitName: "Fitbit",
            calendar: calendar, now: morning
        )
        XCTAssertEqual(summary.title, "Airlift couldn't sync")
        XCTAssertEqual(summary.body, "The network connection was lost.")
    }
}
