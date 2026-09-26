import XCTest
@testable import Airlift

/// HRV recomputed from beat timings, and the artifact filter that decides which
/// beats count. Every expected value here is worked out by hand from the
/// definitions, not captured from a run.
final class TachogramTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_020)

    private func tachogram(_ beats: [(TimeInterval, Bool)]) -> Tachogram {
        Tachogram(
            start: base,
            beats: beats.map { Heartbeat(timeSinceSeriesStart: $0.0, precededByGap: $0.1) }
        )
    }

    // MARK: - Intervals

    func testIntervalsAreDifferencesBetweenBeats() {
        let beats = tachogram([(0, false), (1.0, false), (2.1, false)])
        let intervals = beats.rrIntervals.map { $0.map { ($0 * 1000).rounded() } }
        XCTAssertEqual(intervals, [1000, 1100])
    }

    func testFlaggedGapProducesNoInterval() {
        let beats = tachogram([(0, false), (1.0, false), (2.5, true), (3.5, false)])
        XCTAssertEqual(beats.rrIntervals.count, 3)
        XCTAssertNil(beats.rrIntervals[1])
    }

    // MARK: - RMSSD and SDNN

    func testPerfectlyRegularBeatsHaveNoVariability() {
        let metrics = HRVMetrics.compute(tachogram([(0, false), (1, false), (2, false), (3, false)]))
        XCTAssertEqual(metrics.rmssd, 0)
        XCTAssertEqual(metrics.sdnn, 0)
        XCTAssertEqual(metrics.meanRR, 1000)
        XCTAssertEqual(metrics.successivePairs, 2)
    }

    /// Intervals 1.0, 1.1, 0.9 s. Successive differences +0.1 and -0.2 s, so
    /// RMSSD = sqrt((0.01 + 0.04) / 2) = 0.1581 s, and SDNN (sample, n-1) is
    /// exactly 0.1 s.
    func testRMSSDAndSDNNMatchHandCalculation() throws {
        let metrics = HRVMetrics.compute(tachogram([(0, false), (1.0, false), (2.1, false), (3.0, false)]))
        XCTAssertEqual(try XCTUnwrap(metrics.rmssd), 158.114, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(metrics.sdnn), 100.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(metrics.meanRR), 1000.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(metrics.impliedBPM), 60.0, accuracy: 0.001)
    }

    // MARK: - Artifact filter

    func testMalikRejectsAMissedBeat() {
        // A 0.5 s interval after a run of 1.0 s ones is a doubled beat, not a
        // heart that halved its period for one cycle.
        let metrics = HRVMetrics.compute(
            tachogram([(0, false), (1.0, false), (2.0, false), (2.5, false), (3.5, false)])
        )
        XCTAssertEqual(metrics.rejectedIntervals, 1)
        XCTAssertEqual(metrics.acceptedIntervals, 3)
        // The interval after a rejection is accepted but its difference is not
        // a successive difference — only the first adjacent pair survives.
        XCTAssertEqual(metrics.successivePairs, 1)
        XCTAssertEqual(metrics.rmssd, 0)
    }

    /// The reference is the last *accepted* interval, so one bad beat cannot
    /// drag the threshold with it and reject the good beats that follow.
    func testRejectionDoesNotMoveTheReference() {
        let metrics = HRVMetrics.compute(
            tachogram([(0, false), (1.0, false), (1.4, false), (2.4, false), (3.4, false)])
        )
        XCTAssertEqual(metrics.rejectedIntervals, 1) // the 0.4 s interval
        XCTAssertEqual(metrics.acceptedIntervals, 3) // 1.0, 1.0, 1.0
    }

    func testImplausibleIntervalsAreRejected() {
        // 4 s between beats is 15 bpm — outside the plausible band even though
        // there is no earlier interval to compare it with.
        let metrics = HRVMetrics.compute(tachogram([(0, false), (4.0, false)]))
        XCTAssertEqual(metrics.rejectedIntervals, 1)
        XCTAssertEqual(metrics.acceptedIntervals, 0)
        XCTAssertNil(metrics.rmssd)
    }

    func testGapBreaksTheChainButKeepsBothIntervals() {
        let metrics = HRVMetrics.compute(
            tachogram([(0, false), (1.0, false), (2.5, true), (3.5, false)])
        )
        XCTAssertEqual(metrics.acceptedIntervals, 2)
        XCTAssertEqual(metrics.successivePairs, 0)
        XCTAssertNil(metrics.rmssd, "No adjacent pair survives the gap, so RMSSD is undefined")
    }

    func testRejectionRateReportsHowMuchWasThrownAway() throws {
        let metrics = HRVMetrics.compute(
            tachogram([(0, false), (1.0, false), (2.0, false), (2.5, false), (3.5, false)])
        )
        XCTAssertEqual(try XCTUnwrap(metrics.rejectionRate), 0.25, accuracy: 0.0001)
    }

    /// Loosening the tolerance is not a free knob. At 60% the doubled beat is
    /// accepted, its 0.5 s interval becomes the reference, and the *normal*
    /// beat after it is rejected instead — so the same four intervals still
    /// cost one rejection, and the artifact now lands inside RMSSD: 354 ms
    /// where Malik gives 0.
    func testALooserToleranceLetsTheArtifactIntoRMSSD() throws {
        let beats = tachogram([(0, false), (1.0, false), (2.0, false), (2.5, false), (3.5, false)])
        let malik = HRVMetrics.compute(beats)
        let loose = HRVMetrics.compute(beats, filter: ArtifactFilter(tolerance: 0.6, plausible: 0.3...2.0))

        XCTAssertEqual(malik.rejectedIntervals, loose.rejectedIntervals)
        XCTAssertEqual(malik.rmssd, 0)
        XCTAssertEqual(try XCTUnwrap(loose.rmssd), 353.553, accuracy: 0.01)
        XCTAssertEqual(malik.successivePairs, 1)
        XCTAssertEqual(loose.successivePairs, 2)
    }

    // MARK: - Pooling

    /// Pooling is on the squares, weighted by pairs:
    /// sqrt((3·100² + 1·200²) / 4) = sqrt(17 500) = 132.288.
    func testPoolingWeightsBySuccessivePairs() throws {
        let pooled = HRVMetrics.pooled([
            HRVMetrics(rmssd: 100, sdnn: nil, meanRR: nil, acceptedIntervals: 4, rejectedIntervals: 0, successivePairs: 3),
            HRVMetrics(rmssd: 200, sdnn: nil, meanRR: nil, acceptedIntervals: 2, rejectedIntervals: 0, successivePairs: 1),
        ])
        XCTAssertEqual(try XCTUnwrap(pooled.rmssd), 132.2876, accuracy: 0.001)
        XCTAssertEqual(pooled.successivePairs, 4)
        XCTAssertEqual(pooled.acceptedIntervals, 6)
    }

    /// Averaging the roots instead would give 150 — the difference is the whole
    /// reason pooling is written out rather than taking a mean.
    func testPooledRMSSDIsNotTheMeanOfRMSSDs() throws {
        let pooled = HRVMetrics.pooled([
            HRVMetrics(rmssd: 100, sdnn: nil, meanRR: nil, acceptedIntervals: 4, rejectedIntervals: 0, successivePairs: 3),
            HRVMetrics(rmssd: 200, sdnn: nil, meanRR: nil, acceptedIntervals: 2, rejectedIntervals: 0, successivePairs: 1),
        ])
        XCTAssertNotEqual(try XCTUnwrap(pooled.rmssd), 150, accuracy: 1)
    }

    func testPoolingIgnoresReadingsWithNoUsablePairs() {
        let pooled = HRVMetrics.pooled([
            HRVMetrics(rmssd: nil, sdnn: nil, meanRR: nil, acceptedIntervals: 1, rejectedIntervals: 3, successivePairs: 0),
            HRVMetrics(rmssd: 50, sdnn: nil, meanRR: nil, acceptedIntervals: 3, rejectedIntervals: 0, successivePairs: 2),
        ])
        XCTAssertEqual(pooled.rmssd, 50)
        XCTAssertEqual(pooled.rejectedIntervals, 3)
    }

    func testPoolingNothingYieldsNothing() {
        XCTAssertNil(HRVMetrics.pooled([]).rmssd)
    }
}
