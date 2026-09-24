import XCTest
import HealthKit
@testable import Airlift

/// One night reduced to its nightly numbers: the stage restriction, the onset
/// trim, and the split halves reliability is later computed from.
final class NightRecoveryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_020)

    private func at(_ minutes: Double) -> Date {
        base.addingTimeInterval(minutes * 60)
    }

    private func apple(_ value: HKCategoryValueSleepAnalysis, _ from: Double, _ to: Double) -> AppleSleepSegment {
        AppleSleepSegment(id: UUID(), value: value, start: at(from), end: at(to), sourceName: "Apple Watch")
    }

    private func airliftedStage(_ value: HKCategoryValueSleepAnalysis, _ from: Double, _ to: Double) -> HealthKitReader.OwnSample {
        HealthKitReader.OwnSample(
            id: UUID(), start: at(from), end: at(to), value: Double(value.rawValue), dataPointID: nil
        )
    }

    private func hr(_ minutes: Double, _ bpm: Double) -> HRSample {
        HRSample(id: UUID(), date: at(minutes), bpm: bpm)
    }

    private func airliftedHRV(_ minutes: Double, _ ms: Double) -> HealthKitReader.OwnSample {
        HealthKitReader.OwnSample(
            id: UUID(), start: at(minutes), end: at(minutes), value: ms, dataPointID: nil
        )
    }

    private func appleHRV(_ minutes: Double, _ ms: Double) -> QuantitySample {
        QuantitySample(id: UUID(), start: at(minutes), end: at(minutes), value: ms)
    }

    /// A regular tachogram whose RMSSD is a known value: intervals alternate
    /// 1.0 and 1.0 + `jitter` seconds, so every successive difference is
    /// `jitter` and RMSSD is exactly `jitter` in milliseconds.
    private func tachogram(_ minutes: Double, jitterMS: Double) -> Tachogram {
        var beats: [Heartbeat] = [Heartbeat(timeSinceSeriesStart: 0, precededByGap: false)]
        var time = 0.0
        for step in 0..<20 {
            time += step.isMultiple(of: 2) ? 1.0 : 1.0 + jitterMS / 1000
            beats.append(Heartbeat(timeSinceSeriesStart: time, precededByGap: false))
        }
        return Tachogram(start: at(minutes), beats: beats)
    }

    private func night(
        appleSleep: [AppleSleepSegment] = [],
        airliftedSleep: [HealthKitReader.OwnSample] = [],
        heartRate: [HRSample] = [],
        appleHRV: [QuantitySample] = [],
        airliftedHRV: [HealthKitReader.OwnSample] = [],
        tachograms: [Tachogram] = []
    ) -> NightSamples {
        NightSamples(
            night: base,
            window: DateInterval(start: at(-60), end: at(600)),
            appleSleep: appleSleep,
            airliftedSleep: airliftedSleep,
            appleHeartRate: heartRate,
            appleHRV: appleHRV,
            airliftedHRV: airliftedHRV,
            tachograms: tachograms
        )
    }

    // MARK: - Stage restriction

    func testOnlySamplesInTheSelectedStagesCount() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 60), apple(.asleepREM, 60, 120)],
            heartRate: [hr(10, 60), hr(30, 50), hr(70, 90), hr(100, 100)]
        )
        let nrem = samples.recovery(selection: .coreAndDeep, staging: .apple, onsetTrimMinutes: 0)
        XCTAssertEqual(try XCTUnwrap(nrem.stagedHeartRate).sampleCount, 2)
        XCTAssertEqual(try XCTUnwrap(nrem.stagedHeartRate).value, 55, accuracy: 1e-9)

        let all = samples.recovery(selection: .allSleep, staging: .apple, onsetTrimMinutes: 0)
        XCTAssertEqual(try XCTUnwrap(all.stagedHeartRate).sampleCount, 4)
        XCTAssertEqual(try XCTUnwrap(all.stagedHeartRate).value, 75, accuracy: 1e-9)
    }

    func testStagedMinutesReportTheDenominator() {
        let samples = night(appleSleep: [apple(.asleepCore, 0, 60), apple(.asleepDeep, 60, 90)])
        XCTAssertEqual(samples.recovery(selection: .coreAndDeep, staging: .apple).stagedMinutes, 90)
        XCTAssertEqual(samples.recovery(selection: .deepOnly, staging: .apple).stagedMinutes, 30)
    }

    func testUnscoredNightYieldsNothing() {
        let samples = night(heartRate: [hr(10, 60), hr(30, 50)])
        let recovery = samples.recovery(selection: .coreAndDeep, staging: .apple)
        XCTAssertNil(recovery.stagedHeartRate)
        XCTAssertFalse(recovery.hasStaging)
    }

    // MARK: - Staging source

    /// The comparison this screen exists for: Apple's own samples, labelled by
    /// Fitbit's hypnogram instead of Apple's. Apple calls the second hour REM,
    /// Fitbit calls it deep, and the target zone changes accordingly.
    func testFitbitStagingRelabelsApplesOwnSamples() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 60), apple(.asleepREM, 60, 120)],
            airliftedSleep: [airliftedStage(.asleepCore, 0, 60), airliftedStage(.asleepDeep, 60, 120)],
            heartRate: [hr(30, 60), hr(90, 40)]
        )
        let byApple = samples.recovery(selection: .coreAndDeep, staging: .apple, onsetTrimMinutes: 0)
        let byFitbit = samples.recovery(selection: .coreAndDeep, staging: .fitbit, onsetTrimMinutes: 0)
        XCTAssertEqual(try XCTUnwrap(byApple.stagedHeartRate).sampleCount, 1)
        XCTAssertEqual(try XCTUnwrap(byFitbit.stagedHeartRate).sampleCount, 2)
        XCTAssertEqual(try XCTUnwrap(byFitbit.stagedHeartRate).value, 50, accuracy: 1e-9)
    }

    func testAgreementStagingKeepsOnlyTheSharedMinutes() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 60), apple(.asleepREM, 60, 120)],
            airliftedSleep: [airliftedStage(.asleepCore, 0, 60), airliftedStage(.asleepDeep, 60, 120)],
            heartRate: [hr(30, 60), hr(90, 40)]
        )
        let agreed = samples.recovery(selection: .coreAndDeep, staging: .bothAgree, onsetTrimMinutes: 0)
        XCTAssertEqual(try XCTUnwrap(agreed.stagedHeartRate).sampleCount, 1)
        XCTAssertEqual(agreed.stagedMinutes, 60)
    }

    // MARK: - Onset trim

    func testSleepOnsetIsTrimmed() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 120)],
            heartRate: [hr(10, 70), hr(40, 60), hr(70, 50), hr(100, 40)]
        )
        let trimmed = samples.recovery(selection: .coreAndDeep, staging: .apple, onsetTrimMinutes: 30)
        XCTAssertEqual(try XCTUnwrap(trimmed.stagedHeartRate).sampleCount, 3)
        XCTAssertEqual(try XCTUnwrap(trimmed.stagedHeartRate).value, 50, accuracy: 1e-9)

        let untrimmed = samples.recovery(selection: .coreAndDeep, staging: .apple, onsetTrimMinutes: 0)
        XCTAssertEqual(try XCTUnwrap(untrimmed.stagedHeartRate).value, 55, accuracy: 1e-9)
    }

    func testTrimMeasuresFromSleepOnsetNotTheWindowStart() throws {
        // Sleep starts an hour into the window; the trim must follow it there.
        let samples = night(
            appleSleep: [apple(.asleepCore, 60, 180)],
            heartRate: [hr(70, 70), hr(100, 50)]
        )
        let trimmed = samples.recovery(selection: .coreAndDeep, staging: .apple, onsetTrimMinutes: 30)
        XCTAssertEqual(try XCTUnwrap(trimmed.stagedHeartRate).sampleCount, 1)
        XCTAssertEqual(try XCTUnwrap(trimmed.stagedHeartRate).value, 50, accuracy: 1e-9)
    }

    // MARK: - Split halves

    func testHalvesAreInterleavedNotSequential() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 120)],
            heartRate: [hr(10, 60), hr(20, 50), hr(30, 40), hr(40, 30)]
        )
        let halves = try XCTUnwrap(
            samples.recovery(selection: .coreAndDeep, staging: .apple, onsetTrimMinutes: 0)
                .stagedHeartRate?.halves
        )
        XCTAssertEqual(halves.a, 50, accuracy: 1e-9) // samples 1 and 3
        XCTAssertEqual(halves.b, 40, accuracy: 1e-9) // samples 2 and 4
    }

    /// Three readings a night is the Apple Watch's normal HRV yield, and it
    /// leaves no honest split to make. Saying so beats inventing one.
    func testTooFewSamplesForAHalfReportNoHalves() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 120)],
            airliftedHRV: [airliftedHRV(10, 40), airliftedHRV(50, 50), airliftedHRV(90, 60)]
        )
        let value = try XCTUnwrap(
            samples.recovery(selection: .coreAndDeep, staging: .apple, onsetTrimMinutes: 0).fitbitRMSSD
        )
        XCTAssertEqual(value.sampleCount, 3)
        XCTAssertNil(value.halves, "Two samples in one half and one in the other is not a split")
    }

    // MARK: - Sources stay apart

    /// Apple's HRV and Fitbit's live in the same HealthKit type, separated only
    /// by who wrote them. Mixing them would correlate a series with itself.
    func testAppleAndAirliftedHRVDoNotMix() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 120)],
            appleHRV: [appleHRV(20, 100), appleHRV(60, 100)],
            airliftedHRV: [airliftedHRV(20, 40), airliftedHRV(60, 40)]
        )
        let recovery = samples.recovery(selection: .coreAndDeep, staging: .apple, onsetTrimMinutes: 0)
        XCTAssertEqual(try XCTUnwrap(recovery.appleSDNN).value, 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(recovery.fitbitRMSSD).value, 40, accuracy: 1e-9)
    }

    // MARK: - Recomputed RMSSD

    func testRMSSDIsRecomputedFromBeatSeriesInTheZone() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 60), apple(.asleepREM, 60, 120)],
            tachograms: [tachogram(20, jitterMS: 30), tachogram(90, jitterMS: 200)]
        )
        let recovery = samples.recovery(selection: .coreAndDeep, staging: .apple, onsetTrimMinutes: 0)
        let value = try XCTUnwrap(recovery.appleRMSSD)
        XCTAssertEqual(value.sampleCount, 1, "The REM reading is outside the zone")
        XCTAssertEqual(value.value, 30, accuracy: 0.001)
    }

    func testNoBeatSeriesMeansNoRecomputedRMSSD() {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 120)],
            appleHRV: [appleHRV(20, 55)]
        )
        let recovery = samples.recovery(selection: .coreAndDeep, staging: .apple, onsetTrimMinutes: 0)
        XCTAssertNil(recovery.appleRMSSD)
        XCTAssertNotNil(recovery.appleSDNN, "Apple's published statistic still stands in")
    }

    // MARK: - Orientation

    /// Heart rate runs the other way from HRV — lower is better recovered — so
    /// it has to be flipped before it can be correlated without the answer
    /// coming out backwards.
    func testInvertedHeartRateRunsWithHRV() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 120)],
            heartRate: [hr(10, 50), hr(20, 50)]
        )
        let recovery = samples.recovery(selection: .coreAndDeep, staging: .apple, onsetTrimMinutes: 0)
        XCTAssertEqual(try XCTUnwrap(recovery.stagedHeartRate).value, 50, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(recovery.invertedHeartRate).value, 20, accuracy: 1e-9)
    }

    // MARK: - Chart

    func testChartMarksWhatTheSelectionDropped() throws {
        let samples = night(
            appleSleep: [apple(.asleepCore, 0, 60), apple(.asleepREM, 60, 120)],
            heartRate: [hr(30, 60), hr(90, 55)]
        )
        let chart = samples.chart(selection: .coreAndDeep, staging: .apple)
        XCTAssertEqual(chart.heartRate.count, 2)
        XCTAssertEqual(chart.kept(chart.heartRate).kept, 1)
        XCTAssertEqual(chart.bands.count, 2)
        XCTAssertEqual(chart.bands.filter(\.inZone).count, 1)
    }

    func testChartPrefersRecomputedRMSSDOverPublishedSDNN() {
        let withBeats = night(
            appleSleep: [apple(.asleepCore, 0, 120)],
            appleHRV: [appleHRV(20, 55)],
            tachograms: [tachogram(20, jitterMS: 30)]
        )
        XCTAssertTrue(withBeats.chart(selection: .allSleep, staging: .apple).appleIsRecomputed)

        let withoutBeats = night(
            appleSleep: [apple(.asleepCore, 0, 120)],
            appleHRV: [appleHRV(20, 55)]
        )
        XCTAssertFalse(withoutBeats.chart(selection: .allSleep, staging: .apple).appleIsRecomputed)
    }
}
