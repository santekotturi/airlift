import XCTest
import HealthKit
@testable import Airlift

/// The assembled report: which comparisons appear, how the combined index is
/// built, and the ceiling that bounds every correlation in it.
final class RecoveryReportTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private lazy var firstNight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_020))

    private func night(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: firstNight)!
    }

    /// A night reduced by hand rather than through `NightSamples`, so the
    /// report is tested against values chosen for the assertion.
    private func recovery(
        _ offset: Int,
        fitbit: Double?,
        appleRMSSD: Double? = nil,
        appleSDNN: Double? = nil,
        heartRate: Double? = nil
    ) -> NightRecovery {
        func value(_ raw: Double?) -> SeriesValue? {
            raw.map { SeriesValue(value: $0, sampleCount: 4, halfA: $0 * 0.98, halfB: $0 * 1.02) }
        }
        return NightRecovery(
            night: night(offset),
            window: DateInterval(start: night(offset), duration: 86_400),
            selection: .coreAndDeep,
            staging: .apple,
            fitbitRMSSD: value(fitbit),
            appleRMSSD: value(appleRMSSD),
            appleSDNN: value(appleSDNN),
            stagedHeartRate: value(heartRate),
            stagedMinutes: 240,
            hasStaging: true
        )
    }

    /// Ten nights where every Apple series is a clean function of Fitbit's, so
    /// the expected direction of each statistic is known in advance.
    private var cleanNights: [NightRecovery] {
        let fitbit: [Double] = [38, 44, 51, 40, 47, 55, 42, 49, 36, 53]
        return fitbit.enumerated().map { offset, value in
            recovery(
                offset,
                fitbit: value,
                appleRMSSD: value * 1.2,
                appleSDNN: value * 1.6,
                // Heart rate runs the other way: high HRV, low heart rate.
                heartRate: 100 - value / 2
            )
        }
    }

    private func report(_ nights: [NightRecovery]) -> RecoveryReport {
        RecoveryReport.build(nights: nights, selection: .coreAndDeep, staging: .apple, probe: nil)
    }

    // MARK: - Comparisons

    func testEveryAppleSeriesIsComparedAgainstFitbit() {
        let series = Set(report(cleanNights).comparisons.map(\.series))
        XCTAssertEqual(series, [.appleRMSSD, .appleSDNN, .heartRate, .appleCombined])
    }

    func testProportionalSeriesRankNightsIdentically() throws {
        let comparison = try XCTUnwrap(report(cleanNights).comparison(.appleRMSSD))
        XCTAssertEqual(try XCTUnwrap(comparison.summary.spearman), 1.0, accuracy: 1e-9)
        XCTAssertEqual(comparison.summary.n, 10)
    }

    /// Heart rate is inverted before it is correlated, so a night that is
    /// calmer on Fitbit and slower on the Watch counts as agreement, not
    /// disagreement.
    func testHeartRateIsComparedTheRightWayUp() throws {
        let comparison = try XCTUnwrap(report(cleanNights).comparison(.heartRate))
        XCTAssertEqual(try XCTUnwrap(comparison.summary.spearman), 1.0, accuracy: 1e-9)
    }

    func testOnlyRecomputedRMSSDCarriesABiasFigure() throws {
        let built = report(cleanNights)
        XCTAssertTrue(try XCTUnwrap(built.comparison(.appleRMSSD)).showsBias)
        XCTAssertFalse(try XCTUnwrap(built.comparison(.heartRate)).showsBias)
        XCTAssertFalse(try XCTUnwrap(built.comparison(.appleSDNN)).showsBias)
    }

    func testRecomputedRMSSDReportsHowFarItReadsFromFitbit() throws {
        let comparison = try XCTUnwrap(report(cleanNights).comparison(.appleRMSSD))
        XCTAssertEqual(try XCTUnwrap(comparison.summary.ratioBiasPct), 20.0, accuracy: 0.001)
    }

    func testSeriesWithNoDataProduceNoComparison() {
        let nights = (0..<6).map { recovery($0, fitbit: Double(40 + $0), heartRate: Double(60 - $0)) }
        let built = report(nights)
        XCTAssertNil(built.comparison(.appleRMSSD))
        XCTAssertNotNil(built.comparison(.heartRate))
    }

    func testNightsWithoutFitbitAreNotPaired() throws {
        var nights = cleanNights
        nights[0] = recovery(0, fitbit: nil, appleRMSSD: 50, heartRate: 60)
        let comparison = try XCTUnwrap(report(nights).comparison(.appleRMSSD))
        XCTAssertEqual(comparison.summary.n, 9)
    }

    // MARK: - Combined index

    func testCombinedIndexNeedsBothSides() {
        let hrvOnly = (0..<6).map { recovery($0, fitbit: Double(40 + $0), appleRMSSD: Double(45 + $0)) }
        XCTAssertTrue(report(hrvOnly).combinedIndex.isEmpty)
        XCTAssertNil(report(hrvOnly).comparison(.appleCombined))
    }

    func testCombinedIndexFallsBackToPublishedSDNN() {
        let sdnnOnly = (0..<6).map {
            recovery($0, fitbit: Double(40 + $0), appleSDNN: Double(60 + $0), heartRate: Double(60 - $0))
        }
        XCTAssertEqual(report(sdnnOnly).combinedIndex.count, 6)
    }

    /// The index is exponentiated so it stays positive and its log is exactly
    /// the sum of the two z-scores — which is what lets the log-domain
    /// statistics apply to it unchanged.
    func testCombinedIndexIsPositiveAndLogsToTheZSum() throws {
        let built = report(cleanNights)
        XCTAssertEqual(built.combinedIndex.count, 10)
        for value in built.combinedIndex.values {
            XCTAssertGreaterThan(value, 0)
        }
        // Standardised values sum to zero across the nights, so their logs do too.
        let sum = built.combinedIndex.values.map(log).reduce(0, +)
        XCTAssertEqual(sum, 0, accuracy: 1e-9)
    }

    func testCombinedIndexIsNotGivenACeiling() throws {
        // It has no reliability of its own, so claiming one would be inventing it.
        XCTAssertNil(try XCTUnwrap(report(cleanNights).comparison(.appleCombined)).ceiling)
    }

    // MARK: - Reliability and ceiling

    func testReliabilityCountsNightsAndSamples() throws {
        let entry = try XCTUnwrap(report(cleanNights).reliability(.fitbitRMSSD))
        XCTAssertEqual(entry.nightsWithData, 10)
        XCTAssertEqual(entry.medianSamplesPerNight, 4)
    }

    func testCeilingIsBoundedByTheNoisierSeries() throws {
        let built = report(cleanNights)
        let comparison = try XCTUnwrap(built.comparison(.appleRMSSD))
        let fitbit = try XCTUnwrap(built.reliability(.fitbitRMSSD)?.reliability)
        let apple = try XCTUnwrap(built.reliability(.appleRMSSD)?.reliability)
        XCTAssertEqual(try XCTUnwrap(comparison.ceiling), (fitbit * apple).squareRoot(), accuracy: 1e-9)
        XCTAssertLessThanOrEqual(try XCTUnwrap(comparison.ceiling), max(fitbit, apple))
    }

    // MARK: - Empty

    func testEmptyReportHasNothingToSay() {
        let empty = RecoveryReport.empty(selection: .coreAndDeep, staging: .apple)
        XCTAssertTrue(empty.comparisons.isEmpty)
        XCTAssertTrue(empty.nights.isEmpty)
        XCTAssertEqual(empty.pairedNightCount, 0)
    }

    func testNightsComeBackInTimeOrder() {
        let shuffled = [recovery(4, fitbit: 40), recovery(0, fitbit: 44), recovery(2, fitbit: 48)]
        XCTAssertEqual(report(shuffled).nights.map(\.night), [night(0), night(2), night(4)])
    }
}
