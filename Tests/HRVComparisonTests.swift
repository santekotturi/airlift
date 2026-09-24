import XCTest
import HealthKit
@testable import Airlift

/// Matching each sparse Apple HRV reading to what Fitbit was reporting at the
/// same moment, and the per-zone comparison built on top of it.
final class HRVComparisonTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_020)

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func apple(_ value: HKCategoryValueSleepAnalysis, _ from: Double, _ to: Double) -> AppleSleepSegment {
        AppleSleepSegment(id: UUID(), value: value, start: at(from), end: at(to), sourceName: "Apple Watch")
    }

    private func fitbit(_ minutes: Double, _ ms: Double) -> HealthKitReader.OwnSample {
        HealthKitReader.OwnSample(id: UUID(), start: at(minutes), end: at(minutes), value: ms, dataPointID: nil)
    }

    private func published(_ minutes: Double, _ ms: Double) -> QuantitySample {
        QuantitySample(id: UUID(), start: at(minutes), end: at(minutes), value: ms)
    }

    /// Intervals alternating 1.0 s and 1.0 s + jitter, so RMSSD is exactly
    /// `jitterMS` milliseconds and the expected value is known.
    private func tachogram(_ minutes: Double, jitterMS: Double) -> Tachogram {
        var beats = [Heartbeat(timeSinceSeriesStart: 0, precededByGap: false)]
        var time = 0.0
        for step in 0..<20 {
            time += step.isMultiple(of: 2) ? 1.0 : 1.0 + jitterMS / 1000
            beats.append(Heartbeat(timeSinceSeriesStart: time, precededByGap: false))
        }
        return Tachogram(start: at(minutes), beats: beats)
    }

    private func night(
        appleSleep: [AppleSleepSegment] = [],
        appleHRV: [QuantitySample] = [],
        fitbitHRV: [HealthKitReader.OwnSample] = [],
        tachograms: [Tachogram] = []
    ) -> NightSamples {
        NightSamples(
            night: base,
            window: DateInterval(start: at(-60), end: at(600)),
            appleSleep: appleSleep,
            airliftedSleep: [],
            appleHeartRate: [],
            appleHRV: appleHRV,
            airliftedHRV: fitbitHRV,
            tachograms: tachograms
        )
    }

    // MARK: - Matching

    func testEachAppleReadingBecomesOneWindow() {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 300)],
            tachograms: [tachogram(30, jitterMS: 40), tachogram(150, jitterMS: 50)]
        )
        XCTAssertEqual(samples.hrvWindows(staging: .apple).count, 2)
    }

    func testFitbitReadingsInsideToleranceAreAveraged() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 300)],
            fitbitHRV: [fitbit(28, 40), fitbit(32, 60), fitbit(200, 999)],
            tachograms: [tachogram(30, jitterMS: 40)]
        )
        let window = try XCTUnwrap(samples.hrvWindows(staging: .apple).first)
        XCTAssertEqual(window.fitbitSampleCount, 2, "The 200-minute reading is far outside tolerance")
        XCTAssertEqual(try XCTUnwrap(window.fitbit), 50, accuracy: 1e-9)
    }

    func testAWindowWithNoNearbyFitbitReadingIsIncomplete() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 300)],
            fitbitHRV: [fitbit(200, 45)],
            tachograms: [tachogram(30, jitterMS: 40)]
        )
        let window = try XCTUnwrap(samples.hrvWindows(staging: .apple).first)
        XCTAssertNil(window.fitbit)
        XCTAssertFalse(window.isComplete)
    }

    func testToleranceIsConfigurable() {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 300)],
            fitbitHRV: [fitbit(45, 45)],
            tachograms: [tachogram(30, jitterMS: 40)]
        )
        XCTAssertNil(samples.hrvWindows(staging: .apple).first?.fitbit)
        XCTAssertNotNil(
            samples.hrvWindows(staging: .apple, tolerance: 20 * 60).first?.fitbit
        )
    }

    func testPublishedSDNNIsMatchedToItsOwnReading() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 300)],
            appleHRV: [published(30, 72), published(150, 88)],
            tachograms: [tachogram(30, jitterMS: 40), tachogram(150, jitterMS: 50)]
        )
        let windows = samples.hrvWindows(staging: .apple)
        XCTAssertEqual(windows[0].applePublished, 72)
        XCTAssertEqual(windows[1].applePublished, 88)
    }

    // MARK: - Derived value

    func testDerivedRMSSDIsRecomputedFromTheBeats() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 300)],
            tachograms: [tachogram(30, jitterMS: 42)]
        )
        let window = try XCTUnwrap(samples.hrvWindows(staging: .apple).first)
        XCTAssertEqual(try XCTUnwrap(window.appleDerived), 42, accuracy: 0.001)
        XCTAssertGreaterThan(window.successivePairs, 0)
    }

    func testLocalErrorIsSignedAgainstFitbit() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 300)],
            appleHRV: [published(30, 60)],
            fitbitHRV: [fitbit(30, 50)],
            tachograms: [tachogram(30, jitterMS: 40)]
        )
        let window = try XCTUnwrap(samples.hrvWindows(staging: .apple).first)
        XCTAssertEqual(try XCTUnwrap(window.derivedErrorPct), -20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(window.publishedErrorPct), 20, accuracy: 0.001)
    }

    // MARK: - Zones

    func testWindowsCarryTheStageTheyFellIn() {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 60), apple(.asleepDeep, 60, 120), apple(.asleepREM, 120, 180)],
            tachograms: [
                tachogram(30, jitterMS: 40), tachogram(90, jitterMS: 50), tachogram(150, jitterMS: 60),
            ]
        )
        XCTAssertEqual(samples.hrvWindows(staging: .apple).map(\.stage), [.core, .deep, .rem])
    }

    func testAReadingOutsideScoredSleepHasNoStage() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 60)],
            tachograms: [tachogram(200, jitterMS: 40)]
        )
        XCTAssertNil(try XCTUnwrap(samples.hrvWindows(staging: .apple).first).stage)
    }

    /// A stage with a handful of readings cannot support a correlation, and
    /// showing one anyway is how a fluke becomes a finding.
    func testZonesBelowFiveWindowsAreOmitted() {
        let windows = (0..<4).map { offset in
            HRVWindow(
                id: offset, night: base, at: at(Double(offset) * 60), stage: .deep,
                applePublished: 60, appleDerived: 45, fitbit: 44,
                fitbitSampleCount: 2, rejectionRate: 0.1, successivePairs: 20
            )
        }
        XCTAssertTrue(HRVReport.build(windows: windows, fitbitSamplesPerNight: 90).zones.isEmpty)
    }

    func testZoneReportsMediansAndCount() throws {
        let windows = (0..<6).map { offset in
            HRVWindow(
                id: offset, night: base, at: at(Double(offset) * 60), stage: .core,
                applePublished: 60 + Double(offset),
                appleDerived: 40 + Double(offset),
                fitbit: 44 + Double(offset),
                fitbitSampleCount: 2, rejectionRate: 0.1, successivePairs: 20
            )
        }
        let zone = try XCTUnwrap(
            HRVReport.build(windows: windows, fitbitSamplesPerNight: 90).zone(.core)
        )
        XCTAssertEqual(zone.windowCount, 6)
        XCTAssertEqual(try XCTUnwrap(zone.medians[.appleDerived]), 42.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(zone.derivedSpearman), 1.0, accuracy: 1e-9)
    }

    // MARK: - Report

    func testIncompleteWindowsDoNotEnterTheStatistics() {
        var windows = (0..<6).map { offset in
            HRVWindow(
                id: offset, night: base, at: at(Double(offset) * 60), stage: .core,
                applePublished: 60, appleDerived: 40 + Double(offset), fitbit: 44 + Double(offset),
                fitbitSampleCount: 2, rejectionRate: 0.1, successivePairs: 20
            )
        }
        windows.append(
            HRVWindow(
                id: 99, night: base, at: at(500), stage: .core,
                applePublished: 60, appleDerived: 40, fitbit: nil,
                fitbitSampleCount: 0, rejectionRate: 0.1, successivePairs: 20
            )
        )
        let report = HRVReport.build(windows: windows, fitbitSamplesPerNight: 90)
        XCTAssertEqual(report.windows.count, 7)
        XCTAssertEqual(report.completeWindowCount, 6)
        XCTAssertEqual(report.derivedOverall.n, 6)
    }

    func testReportCountsNightsAndDensity() {
        let windows = (0..<6).map { offset in
            HRVWindow(
                id: offset,
                night: offset < 3 ? base : base.addingTimeInterval(86_400),
                at: at(Double(offset) * 60), stage: .core,
                applePublished: 60, appleDerived: 40, fitbit: 44,
                fitbitSampleCount: 2, rejectionRate: 0.1, successivePairs: 20
            )
        }
        let report = HRVReport.build(windows: windows, fitbitSamplesPerNight: 92)
        XCTAssertEqual(report.nightCount, 2)
        XCTAssertEqual(report.appleWindowsPerNight, 3)
        XCTAssertEqual(report.fitbitSamplesPerNight, 92)
    }

    func testEmptyReportIsSafe() {
        let report = HRVReport.build(windows: [], fitbitSamplesPerNight: nil)
        XCTAssertEqual(report.nightCount, 0)
        XCTAssertTrue(report.zones.isEmpty)
        XCTAssertEqual(report.derivedOverall.n, 0)
    }
}
