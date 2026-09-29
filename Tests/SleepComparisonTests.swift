import HealthKit
import XCTest
@testable import Airlift

final class SleepComparisonTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func watch(_ value: HKCategoryValueSleepAnalysis, _ from: Double, _ to: Double) -> AppleSleepSegment {
        AppleSleepSegment(id: UUID(), value: value, start: at(from), end: at(to), sourceName: "Sante’s Apple Watch Ultra 4")
    }

    private func fitbit(_ value: HKCategoryValueSleepAnalysis, _ from: Double, _ to: Double) -> HealthKitReader.OwnSample {
        HealthKitReader.OwnSample(id: UUID(), start: at(from), end: at(to), value: Double(value.rawValue), dataPointID: nil)
    }

    private func night(apple: [AppleSleepSegment], fitbit: [HealthKitReader.OwnSample]) -> NightSamples {
        NightSamples(
            night: base, window: DateInterval(start: at(-600), end: at(1_200)),
            appleSleep: apple, airliftedSleep: fitbit, appleHeartRate: [],
            appleHRV: [], airliftedHRV: [], tachograms: []
        )
    }

    func testStageMinutesCountOverlapsOnce() throws {
        let minutes = try XCTUnwrap(StageMinutes([
            (.core, at(0), at(60)),
            (.deep, at(30), at(90)),   // overlaps the core span
        ]))
        XCTAssertEqual(minutes.core, 30)
        XCTAssertEqual(minutes.deep, 60)
        XCTAssertEqual(minutes.asleep, 90)
    }

    func testNightComparesEachStage() throws {
        let report = SleepComparisonReport.build([
            night(
                apple: [watch(.asleepCore, 0, 240), watch(.asleepDeep, 240, 280), watch(.awake, 280, 290), watch(.asleepREM, 290, 400)],
                fitbit: [fitbit(.asleepCore, 0, 200), fitbit(.asleepDeep, 200, 290), fitbit(.asleepREM, 290, 400)]
            ),
        ])
        let summary = try XCTUnwrap(report.summary(.deep))
        XCTAssertEqual(summary.watchMean, 40)
        XCTAssertEqual(summary.fitbitMean, 90)
        XCTAssertEqual(summary.meanDifference, 50)
        XCTAssertEqual(report.nights.first?.watchDevice, "Watch Ultra 4")
        XCTAssertEqual(try XCTUnwrap(report.summary(.total)).watchMean, 390)
    }

    func testWatchKeepsOnlyItsMainSleep() throws {
        let report = SleepComparisonReport.build([
            night(
                apple: [watch(.asleepCore, -300, -240), watch(.asleepCore, 0, 420)],
                fitbit: [fitbit(.asleepCore, 0, 420)]
            ),
        ])
        XCTAssertEqual(try XCTUnwrap(report.nights.first?.watch).asleep, 420)
    }

    func testInBedIsNotSleep() throws {
        let report = SleepComparisonReport.build([
            night(apple: [watch(.inBed, -30, 450), watch(.asleepCore, 0, 420)], fitbit: []),
        ])
        let watch = try XCTUnwrap(report.nights.first?.watch)
        XCTAssertEqual(watch.asleep, 420)
        XCTAssertFalse(report.nights[0].isPaired)
        XCTAssertNil(report.summary(.total))
    }
}
