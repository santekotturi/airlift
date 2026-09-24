import XCTest
@testable import Airlift

/// Cross-validation against the reference implementation.
///
/// `TachogramTests` proves the arithmetic against examples worked out by hand.
/// This proves the same code agrees with `recoverylab`'s Python implementation
/// on six real Apple Watch tachograms pulled out of a Health export — beats
/// neither implementation was written against, carrying the ectopics, dropped
/// beats and long gaps that hand-built examples never have.
///
/// If a change to `ArtifactFilter` or `HRVMetrics` breaks these, the app and
/// the analysis behind the whitepaper have diverged, and one of them is now
/// reporting numbers the other cannot reproduce.
///
/// Regenerate with `recoverylab/analysis/validate_rr_hrv.py`.
final class TachogramFixtureTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_750_000_020)

    private func tachogram(_ testCase: TachogramFixtures.Case) -> Tachogram {
        Tachogram(
            start: start,
            // The export carries no gap flags, so every beat is presented as
            // continuous and the filter has to catch the gaps on its own —
            // exactly the conditions the Python reference ran under.
            beats: testCase.offsets.map {
                Heartbeat(timeSinceSeriesStart: $0, precededByGap: false)
            }
        )
    }

    func testFixturesExist() {
        XCTAssertEqual(TachogramFixtures.all.count, 6)
        for testCase in TachogramFixtures.all {
            XCTAssertGreaterThan(testCase.offsets.count, 3, "record \(testCase.record)")
        }
    }

    func testRMSSDMatchesTheReferenceImplementation() throws {
        for testCase in TachogramFixtures.all {
            let metrics = HRVMetrics.compute(tachogram(testCase))
            XCTAssertEqual(
                try XCTUnwrap(metrics.rmssd), testCase.rmssd, accuracy: 0.001,
                "RMSSD diverged on record \(testCase.record)"
            )
        }
    }

    func testSDNNMatchesTheReferenceImplementation() throws {
        for testCase in TachogramFixtures.all {
            let metrics = HRVMetrics.compute(tachogram(testCase))
            XCTAssertEqual(
                try XCTUnwrap(metrics.sdnn), testCase.sdnn, accuracy: 0.001,
                "SDNN diverged on record \(testCase.record)"
            )
        }
    }

    func testMeanIntervalMatchesTheReferenceImplementation() throws {
        for testCase in TachogramFixtures.all {
            let metrics = HRVMetrics.compute(tachogram(testCase))
            XCTAssertEqual(
                try XCTUnwrap(metrics.meanRR), testCase.meanRR, accuracy: 0.001,
                "Mean RR diverged on record \(testCase.record)"
            )
        }
    }

    /// The filter has to reject the same intervals, not merely land on the same
    /// number by luck — two filters can agree on RMSSD while disagreeing about
    /// which beats were real.
    func testTheFilterAcceptsTheSameIntervals() {
        for testCase in TachogramFixtures.all {
            let metrics = HRVMetrics.compute(tachogram(testCase))
            XCTAssertEqual(
                metrics.acceptedIntervals, testCase.acceptedIntervals,
                "Accepted count diverged on record \(testCase.record)"
            )
            XCTAssertEqual(
                metrics.successivePairs, testCase.successivePairs,
                "Successive pairs diverged on record \(testCase.record)"
            )
        }
    }

    /// Recomputed SDNN tracks Apple's published number for the same beats but
    /// reads low, because Malik rejects intervals Apple keeps. Confirming the
    /// direction here is what licenses recomputing RMSSD at all: if the
    /// reconstruction were wrong, the two would not be in the same neighbourhood.
    func testRecomputedSDNNIsCloseToApplesOwnButLower() throws {
        var lower = 0
        for testCase in TachogramFixtures.all {
            let sdnn = try XCTUnwrap(HRVMetrics.compute(tachogram(testCase)).sdnn)
            XCTAssertEqual(
                sdnn, testCase.publishedSDNN, accuracy: testCase.publishedSDNN,
                "Recomputed SDNN is not even the same order as Apple's on record \(testCase.record)"
            )
            if sdnn < testCase.publishedSDNN { lower += 1 }
        }
        XCTAssertGreaterThanOrEqual(
            lower, TachogramFixtures.all.count / 2,
            "Rejecting artifacts should lower dispersion on most readings"
        )
    }

    /// Real beats, unlike hand-built ones, actually exercise the filter.
    func testRealReadingsContainArtifacts() {
        let rejected = TachogramFixtures.all
            .map { HRVMetrics.compute(tachogram($0)).rejectedIntervals }
            .reduce(0, +)
        XCTAssertGreaterThan(rejected, 0, "No fixture exercises the artifact filter")
    }
}
