import XCTest
import HealthKit
@testable import Airlift

final class StageMapperTests: XCTestCase {
    func testStageMappings() {
        let cases: [(SleepStage, HKCategoryValueSleepAnalysis)] = [
            (.wake, .awake),
            (.light, .asleepCore),
            (.deep, .asleepDeep),
            (.rem, .asleepREM),
            (.asleep, .asleepUnspecified),
            (.restless, .awake),
            (.unknown, .asleepUnspecified),
        ]
        for (stage, expected) in cases {
            XCTAssertEqual(StageMapper.healthKitValue(for: stage), expected, "stage \(stage)")
        }
    }

    func testUnknownWireValueDecodesToUnknown() {
        XCTAssertEqual(SleepStage(wireValue: "something-new"), .unknown)
        XCTAssertEqual(SleepStage(wireValue: "REM"), .rem) // case-insensitive
        XCTAssertEqual(SleepStage(wireValue: "deep"), .deep)
    }

    func testEveryStageHasAMapping() {
        // Guards against adding a SleepStage case without mapping it.
        for stage in SleepStage.allCases {
            _ = StageMapper.healthKitValue(for: stage)
        }
    }
}
