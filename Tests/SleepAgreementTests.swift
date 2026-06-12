import XCTest
import HealthKit
@testable import AirKit

final class SleepAgreementTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func google(_ stage: SleepStage, _ startMin: Int, _ endMin: Int) -> SleepStageSegment {
        SleepStageSegment(
            stage: stage,
            start: base.addingTimeInterval(Double(startMin) * 60),
            end: base.addingTimeInterval(Double(endMin) * 60)
        )
    }

    private func apple(_ value: HKCategoryValueSleepAnalysis, _ startMin: Int, _ endMin: Int) -> AppleSleepSegment {
        AppleSleepSegment(
            id: UUID(),
            value: value,
            start: base.addingTimeInterval(Double(startMin) * 60),
            end: base.addingTimeInterval(Double(endMin) * 60),
            sourceName: "Apple Watch"
        )
    }

    func testIdenticalLanesAgreeFully() {
        let percent = SleepAgreement.percent(
            google: [google(.light, 0, 60), google(.deep, 60, 120)],
            apple: [apple(.asleepCore, 0, 60), apple(.asleepDeep, 60, 120)]
        )
        XCTAssertEqual(percent, 100)
    }

    func testOppositeLanesAgreeNever() {
        let percent = SleepAgreement.percent(
            google: [google(.wake, 0, 60)],
            apple: [apple(.asleepDeep, 0, 60)]
        )
        XCTAssertEqual(percent, 0)
    }

    func testHalfOverlapScoresHalf() {
        // First hour matches (core/core), second hour differs (deep vs REM).
        let percent = SleepAgreement.percent(
            google: [google(.light, 0, 60), google(.deep, 60, 120)],
            apple: [apple(.asleepCore, 0, 60), apple(.asleepREM, 60, 120)]
        )
        XCTAssertEqual(percent!, 50, accuracy: 1)
    }

    func testGenericAsleepMatchesAnySleepStage() {
        // Apple only knows "asleep"; Google has stage detail. They agree.
        let percent = SleepAgreement.percent(
            google: [google(.light, 0, 30), google(.rem, 30, 60)],
            apple: [apple(.asleepUnspecified, 0, 60)]
        )
        XCTAssertEqual(percent, 100)
    }

    func testGenericAsleepDoesNotMatchAwake() {
        let percent = SleepAgreement.percent(
            google: [google(.wake, 0, 60)],
            apple: [apple(.asleepUnspecified, 0, 60)]
        )
        XCTAssertEqual(percent, 0)
    }

    func testInBedSegmentsAreIgnored() {
        // An in-bed span across the whole night must not dilute agreement.
        let percent = SleepAgreement.percent(
            google: [google(.light, 0, 60)],
            apple: [apple(.inBed, 0, 120), apple(.asleepCore, 0, 60)]
        )
        XCTAssertEqual(percent, 100)
    }

    func testNonOverlappingWindowsHaveNothingToCompare() {
        let percent = SleepAgreement.percent(
            google: [google(.light, 0, 60)],
            apple: [apple(.asleepCore, 120, 180)]
        )
        XCTAssertNil(percent)
    }

    func testNoAppleDataReturnsNil() {
        XCTAssertNil(SleepAgreement.percent(google: [google(.light, 0, 60)], apple: []))
        XCTAssertNil(SleepAgreement.percent(google: [], apple: [apple(.asleepCore, 0, 60)]))
    }

    func testOffsetLanesOnlyCompareSharedMinutes() {
        // Apple starts 30 min later; the shared 30 minutes agree → 100%.
        let percent = SleepAgreement.percent(
            google: [google(.light, 0, 60)],
            apple: [apple(.asleepCore, 30, 90)]
        )
        XCTAssertEqual(percent, 100)
    }
}
