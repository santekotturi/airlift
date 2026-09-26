import XCTest
@testable import Airlift

/// The method-comparison statistics. Expected values are worked out from the
/// definitions by hand so a change in the implementation has to justify itself
/// against arithmetic, not against a previous run.
final class RecoveryStatsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_020)))!
    }

    // MARK: - Correlation

    func testPerfectAgreementIsOne() throws {
        XCTAssertEqual(try XCTUnwrap(RecoveryStats.pearson([1, 2, 3, 4], [2, 4, 6, 8])), 1.0, accuracy: 1e-12)
    }

    func testPerfectDisagreementIsMinusOne() throws {
        XCTAssertEqual(try XCTUnwrap(RecoveryStats.pearson([1, 2, 3, 4], [4, 3, 2, 1])), -1.0, accuracy: 1e-12)
    }

    func testConstantSeriesHasNoCorrelation() {
        XCTAssertNil(RecoveryStats.pearson([1, 1, 1, 1], [1, 2, 3, 4]))
    }

    func testTooFewPointsIsNotACorrelation() {
        XCTAssertNil(RecoveryStats.pearson([1, 2], [1, 2]))
        XCTAssertNil(RecoveryStats.spearman([1, 2], [1, 2]))
    }

    /// The reason ranks are used: a monotone but curved relationship is perfect
    /// agreement about the ordering, which is what a recovery metric is read for.
    func testSpearmanSeesMonotoneAgreementPearsonMisses() throws {
        let x: [Double] = [1, 2, 3, 4, 5]
        let y: [Double] = [1, 4, 9, 16, 25]
        XCTAssertEqual(try XCTUnwrap(RecoveryStats.spearman(x, y)), 1.0, accuracy: 1e-12)
        XCTAssertLessThan(try XCTUnwrap(RecoveryStats.pearson(x, y)), 0.99)
    }

    func testTiedValuesShareTheirAverageRank() {
        XCTAssertEqual(RecoveryStats.ranks([10, 20, 20, 30]), [1, 2.5, 2.5, 4])
    }

    func testRanksFollowTheOriginalOrder() {
        XCTAssertEqual(RecoveryStats.ranks([30, 10, 20]), [3, 1, 2])
    }

    // MARK: - Interval

    /// atanh(0.5) = 0.549306, se = 1/sqrt(27) = 0.192450, so the interval is
    /// tanh(0.549306 ∓ 0.377203) = 0.1704 to 0.7291.
    func testFisherIntervalMatchesHandCalculation() throws {
        let interval = try XCTUnwrap(RecoveryStats.fisherInterval(0.5, n: 30))
        XCTAssertEqual(interval.low, 0.1704, accuracy: 0.001)
        XCTAssertEqual(interval.high, 0.7291, accuracy: 0.001)
    }

    func testIntervalNarrowsWithMoreNights() throws {
        let few = try XCTUnwrap(RecoveryStats.fisherInterval(0.5, n: 12))
        let many = try XCTUnwrap(RecoveryStats.fisherInterval(0.5, n: 120))
        XCTAssertGreaterThan(few.high - few.low, many.high - many.low)
    }

    func testNoIntervalForAPerfectCorrelation() {
        XCTAssertNil(RecoveryStats.fisherInterval(1.0, n: 30))
    }

    // MARK: - Concordance

    func testConcordanceIsOneOnTheIdentityLine() throws {
        let values: [Double] = [1, 2, 3, 4, 5]
        XCTAssertEqual(try XCTUnwrap(RecoveryStats.concordance(values, values)), 1.0, accuracy: 1e-12)
    }

    /// The failure Pearson cannot see: a device that tracks perfectly and reads
    /// consistently high correlates at 1.0 and concords well below it.
    func testConcordancePenalisesAConstantOffset() throws {
        let reference: [Double] = [1, 2, 3, 4, 5]
        let shifted = reference.map { $0 + 3 }
        XCTAssertEqual(try XCTUnwrap(RecoveryStats.pearson(reference, shifted)), 1.0, accuracy: 1e-12)
        XCTAssertLessThan(try XCTUnwrap(RecoveryStats.concordance(reference, shifted)), 0.5)
    }

    // MARK: - Comparison

    private func pairs(_ values: [(Double, Double)]) -> [RecoveryStats.PairedNight] {
        values.enumerated().map { offset, pair in
            RecoveryStats.PairedNight(night: day(offset), reference: pair.0, target: pair.1)
        }
    }

    func testComparisonReportsRankAgreementAndCount() throws {
        let summary = RecoveryStats.compare(pairs([(40, 80), (50, 100), (60, 120), (70, 140), (80, 160)]))
        XCTAssertEqual(summary.n, 5)
        XCTAssertEqual(try XCTUnwrap(summary.spearman), 1.0, accuracy: 1e-12)
    }

    /// A target that is exactly double the reference reads 100% high, with
    /// limits of agreement that collapse onto the bias because nothing varies.
    func testRatioBiasIsAPercentage() throws {
        let summary = RecoveryStats.compare(pairs([(40, 80), (50, 100), (60, 120), (70, 140)]))
        XCTAssertEqual(try XCTUnwrap(summary.ratioBiasPct), 100.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.ratioLoALowPct), 100.0, accuracy: 0.001)
    }

    func testNonPositiveAndNonFiniteNightsAreDropped() {
        let summary = RecoveryStats.compare([
            RecoveryStats.PairedNight(night: day(0), reference: 40, target: 80),
            RecoveryStats.PairedNight(night: day(1), reference: 0, target: 90),
            RecoveryStats.PairedNight(night: day(2), reference: 50, target: .nan),
            RecoveryStats.PairedNight(night: day(3), reference: 60, target: 120),
            RecoveryStats.PairedNight(night: day(4), reference: 70, target: 140),
        ])
        XCTAssertEqual(summary.n, 3)
    }

    func testTooFewNightsReportsCountWithoutStatistics() {
        let summary = RecoveryStats.compare(pairs([(40, 80), (50, 100)]))
        XCTAssertEqual(summary.n, 2)
        XCTAssertNil(summary.spearman)
    }

    func testUnderpoweredIsFlaggedRatherThanHidden() {
        XCTAssertTrue(RecoveryStats.compare(pairs([(40, 80), (50, 100), (60, 120)])).isUnderpowered)
    }

    // MARK: - Change agreement

    func testOnlyConsecutiveNightsContributeChanges() {
        let scattered = [
            RecoveryStats.PairedNight(night: day(0), reference: 40, target: 80),
            RecoveryStats.PairedNight(night: day(1), reference: 50, target: 100),
            // A ten-day gap: the "change" across it is not a night-to-night move.
            RecoveryStats.PairedNight(night: day(11), reference: 60, target: 120),
            RecoveryStats.PairedNight(night: day(12), reference: 45, target: 90),
            RecoveryStats.PairedNight(night: day(13), reference: 55, target: 110),
        ]
        let change = RecoveryStats.changeAgreement(scattered, calendar: calendar)
        XCTAssertEqual(change.n, 3, "One consecutive pair plus two — the gap is skipped")
    }

    func testProportionalTargetTracksChangesPerfectly() throws {
        let change = RecoveryStats.changeAgreement(
            pairs([(40, 80), (55, 110), (48, 96), (62, 124), (51, 102)]),
            calendar: calendar
        )
        XCTAssertEqual(try XCTUnwrap(change.rho), 1.0, accuracy: 1e-12)
        XCTAssertEqual(change.n, 4)
    }

    /// Levels can agree while changes do not — the case that decides whether a
    /// device can answer "am I more recovered than yesterday". Here the nights
    /// rank at ρ = 0.93 and the night-to-night moves at ρ = −0.20.
    func testLevelAgreementDoesNotImplyChangeAgreement() throws {
        let summary = RecoveryStats.compare(pairs([
            (40, 45), (44, 41), (48, 53), (52, 49), (56, 57), (60, 61), (64, 65),
        ]))
        XCTAssertGreaterThan(try XCTUnwrap(summary.spearman), 0.9)
        XCTAssertLessThan(try XCTUnwrap(summary.changeSpearman), 0)
    }

    // MARK: - Reliability

    func testIdenticalHalvesAreFullyReliable() throws {
        let halves = (1...10).map { (a: Double($0) * 10, b: Double($0) * 10) }
        XCTAssertEqual(try XCTUnwrap(RecoveryStats.splitHalfReliability(halves)), 1.0, accuracy: 1e-9)
    }

    /// Spearman-Brown lifts the half-length correlation to the reliability of
    /// the whole measurement — each half saw only half the samples. These
    /// halves correlate at 0.823, which is a reliability of 0.903.
    func testSpearmanBrownCorrectsForHalfLength() throws {
        let a: [Double] = [1, 2, 3, 4, 5, 6, 7, 8]
        let b: [Double] = [2, 1, 4, 3, 6, 5, 8, 7]
        let raw = try XCTUnwrap(RecoveryStats.pearson(a.map(log), b.map(log)))
        let corrected = try XCTUnwrap(RecoveryStats.splitHalfReliability(Array(zip(a, b)).map { (a: $0.0, b: $0.1) }))
        XCTAssertEqual(corrected, 2 * raw / (1 + raw), accuracy: 1e-9)
        XCTAssertGreaterThan(corrected, raw)
    }

    func testUncorrelatedHalvesReportNoSignal() throws {
        let halves: [(a: Double, b: Double)] = [
            (10, 50), (20, 10), (30, 40), (40, 20), (50, 30), (60, 60), (15, 45), (35, 25),
        ]
        XCTAssertLessThan(try XCTUnwrap(RecoveryStats.splitHalfReliability(halves)), 0.6)
    }

    func testReliabilityIsClampedToUnitRange() throws {
        let halves: [(a: Double, b: Double)] = [
            (10, 60), (20, 50), (30, 40), (40, 30), (50, 20), (60, 10),
        ]
        let reliability = try XCTUnwrap(RecoveryStats.splitHalfReliability(halves))
        XCTAssertGreaterThanOrEqual(reliability, 0)
        XCTAssertLessThanOrEqual(reliability, 1)
    }

    func testTooFewNightsHasNoReliability() {
        XCTAssertNil(RecoveryStats.splitHalfReliability([(a: 1, b: 1), (a: 2, b: 2)]))
    }

    // MARK: - Ceiling

    /// sqrt(0.64 · 0.49) = 0.56 — the best two instruments this noisy could
    /// ever have scored against each other.
    func testCeilingIsTheGeometricMeanOfReliabilities() throws {
        XCTAssertEqual(try XCTUnwrap(RecoveryStats.attenuationCeiling(0.64, 0.49)), 0.56, accuracy: 1e-9)
    }

    func testNoCeilingWithoutBothReliabilities() {
        XCTAssertNil(RecoveryStats.attenuationCeiling(0.8, nil))
        XCTAssertNil(RecoveryStats.attenuationCeiling(0, 0.8))
    }

    func testDisattenuationDividesOutMeasurementNoise() throws {
        XCTAssertEqual(
            try XCTUnwrap(RecoveryStats.disattenuated(0.28, 0.64, 0.49)), 0.5, accuracy: 1e-9
        )
    }

    /// A correlation above 1 is not a finding, however the reliabilities came out.
    func testDisattenuationNeverExceedsOne() throws {
        XCTAssertEqual(try XCTUnwrap(RecoveryStats.disattenuated(0.9, 0.3, 0.3)), 1.0)
    }

    // MARK: - Descriptives

    func testMedianOfEvenCountAveragesTheMiddle() {
        XCTAssertEqual(RecoveryStats.median([4, 1, 3, 2]), 2.5)
    }

    func testMedianOfOddCountIsTheMiddle() {
        XCTAssertEqual(RecoveryStats.median([5, 1, 3]), 3)
    }

    func testStandardDeviationIsTheSampleVersion() throws {
        // Sample SD of 2, 4, 4, 4, 5, 5, 7, 9 is sqrt(32/7) = 2.13809.
        XCTAssertEqual(
            try XCTUnwrap(RecoveryStats.standardDeviation([2, 4, 4, 4, 5, 5, 7, 9])),
            2.13809, accuracy: 0.0001
        )
    }
}
