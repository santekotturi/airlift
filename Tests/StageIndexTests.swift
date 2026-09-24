import XCTest
import HealthKit
@testable import Airlift

/// The minute grid a night's samples are labelled against, and the stage
/// restrictions built on it.
final class StageIndexTests: XCTestCase {
    /// Minute-aligned, so a span of N minutes covers exactly N grid cells.
    private let base = Date(timeIntervalSince1970: 1_750_000_020)

    private func at(_ minutes: Double) -> Date {
        base.addingTimeInterval(minutes * 60)
    }

    private func span(_ stage: SleepAgreement.Stage, _ from: Double, _ to: Double)
        -> (stage: SleepAgreement.Stage, start: Date, end: Date) {
        (stage: stage, start: at(from), end: at(to))
    }

    private func apple(_ value: HKCategoryValueSleepAnalysis, _ from: Double, _ to: Double) -> AppleSleepSegment {
        AppleSleepSegment(id: UUID(), value: value, start: at(from), end: at(to), sourceName: "Apple Watch")
    }

    private func airlifted(_ value: HKCategoryValueSleepAnalysis, _ from: Double, _ to: Double) -> HealthKitReader.OwnSample {
        HealthKitReader.OwnSample(
            id: UUID(), start: at(from), end: at(to), value: Double(value.rawValue), dataPointID: nil
        )
    }

    private var night: StageIndex {
        StageIndex(spans: [span(.core, 0, 60), span(.deep, 60, 90), span(.rem, 90, 120)])
    }

    // MARK: - Labelling

    func testSampleTakesTheStageOfItsMinute() {
        XCTAssertEqual(night.stage(at: at(30)), .core)
        XCTAssertEqual(night.stage(at: at(75)), .deep)
        XCTAssertEqual(night.stage(at: at(110)), .rem)
    }

    func testUnscoredMinutesHaveNoStage() {
        XCTAssertNil(night.stage(at: at(-5)))
        XCTAssertNil(night.stage(at: at(200)))
    }

    /// A sample in an unscored minute is excluded, never assumed asleep — the
    /// difference between "not in the zone" and "we do not know".
    func testUnscoredSamplesAreExcludedFromEverySelection() {
        for selection in StageSelection.allCases {
            XCTAssertFalse(night.includes(at(200), in: selection))
        }
    }

    func testLaterSegmentsCorrectEarlierOnes() {
        let index = StageIndex(spans: [span(.core, 0, 60), span(.deep, 30, 60)])
        XCTAssertEqual(index.stage(at: at(10)), .core)
        XCTAssertEqual(index.stage(at: at(45)), .deep)
    }

    // MARK: - Selections

    func testSelectionsCoverTheExpectedMinutes() {
        XCTAssertEqual(night.minuteCount(in: .allSleep), 120)
        XCTAssertEqual(night.minuteCount(in: .coreAndDeep), 90)
        XCTAssertEqual(night.minuteCount(in: .deepOnly), 30)
    }

    func testCoreAndDeepExcludesREM() {
        XCTAssertTrue(night.includes(at(75), in: .coreAndDeep))
        XCTAssertFalse(night.includes(at(110), in: .coreAndDeep))
    }

    /// Generic "asleep" means stage unknown. Counting it as NREM would fill the
    /// target zone with minutes that might be REM.
    func testGenericAsleepCountsAsSleepButNotAsNREM() {
        let index = StageIndex(spans: [span(.asleep, 0, 60)])
        XCTAssertEqual(index.minuteCount(in: .allSleep), 60)
        XCTAssertEqual(index.minuteCount(in: .coreAndDeep), 0)
        XCTAssertEqual(index.minuteCount(in: .deepOnly), 0)
    }

    func testAwakeIsNeverIncluded() {
        let index = StageIndex(spans: [span(.awake, 0, 60)])
        for selection in StageSelection.allCases {
            XCTAssertEqual(index.minuteCount(in: selection), 0)
        }
    }

    // MARK: - Sources

    func testAppleSegmentsMapOntoTheGrid() {
        let index = StageIndex(apple: [apple(.asleepCore, 0, 60), apple(.asleepDeep, 60, 90)])
        XCTAssertEqual(index.minuteCount(in: .coreAndDeep), 90)
        XCTAssertEqual(index.minuteCount(in: .deepOnly), 30)
    }

    func testInBedIsIgnored() {
        // `.inBed` overlaps real stages and says nothing about sleep state.
        let index = StageIndex(apple: [apple(.inBed, 0, 120), apple(.asleepDeep, 60, 90)])
        XCTAssertEqual(index.scoredMinuteCount, 30)
    }

    func testAirliftedSamplesMapOntoTheGrid() {
        let index = StageIndex(airlifted: [airlifted(.asleepDeep, 0, 45)])
        XCTAssertEqual(index.minuteCount(in: .deepOnly), 45)
    }

    // MARK: - Agreement

    func testIntersectionKeepsOnlyMinutesBothSourcesScoreAlike() {
        let apple = StageIndex(spans: [span(.core, 0, 60)])
        let fitbit = StageIndex(spans: [span(.core, 0, 30), span(.deep, 30, 60)])
        let agreed = StageIndex.intersection(apple, fitbit)
        XCTAssertEqual(agreed.scoredMinuteCount, 30)
        XCTAssertEqual(agreed.stage(at: at(10)), .core)
        XCTAssertNil(agreed.stage(at: at(45)))
    }

    /// One source knowing only "asleep" should not erase the other's stage —
    /// they agree the person was asleep, and only one of them can say more.
    func testUnstagedSleepDefersToTheSourceThatHasAStage() {
        let unstaged = StageIndex(spans: [span(.asleep, 0, 60)])
        let staged = StageIndex(spans: [span(.deep, 0, 60)])
        let agreed = StageIndex.intersection(unstaged, staged)
        XCTAssertEqual(agreed.minuteCount(in: .deepOnly), 60)
    }

    func testIntersectionOfDisjointNightsIsEmpty() {
        let first = StageIndex(spans: [span(.core, 0, 60)])
        let second = StageIndex(spans: [span(.core, 120, 180)])
        XCTAssertTrue(StageIndex.intersection(first, second).isEmpty)
    }

    // MARK: - Structure

    func testBoutsAreContiguousRuns() {
        let index = StageIndex(spans: [
            span(.deep, 0, 30), span(.core, 30, 60), span(.deep, 60, 80),
        ])
        let bouts = index.bouts(of: .deep)
        XCTAssertEqual(bouts.count, 2)
        XCTAssertEqual(bouts.first?.duration, 30 * 60)
        XCTAssertEqual(bouts.last?.duration, 20 * 60)
    }

    func testRunsComeBackInTimeOrder() {
        let runs = night.runs()
        XCTAssertEqual(runs.map { $0.stage }, [.core, .deep, .rem])
        XCTAssertEqual(runs.first?.interval.start, at(0))
        XCTAssertEqual(runs.last?.interval.end, at(120))
    }

    func testEmptyNightHasNoRuns() {
        XCTAssertTrue(StageIndex.empty.runs().isEmpty)
        XCTAssertTrue(StageIndex.empty.isEmpty)
    }
}
