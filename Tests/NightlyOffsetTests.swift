import XCTest
@testable import Airlift

final class NightlyOffsetTests: XCTestCase {
    /// Twelve synthetic nights shaped like a real Apple Watch / Fitbit pair:
    /// Fitbit ~0.77× Apple, give or take a ms of rounding noise.
    private let apple: [Double] = [70, 55, 62, 80, 66, 74, 58, 88, 77, 69, 83, 60]
    private let fitbit: [Double] = [54, 43, 47, 62, 51, 56, 45, 67, 60, 53, 64, 46]

    private var offset: NightlyOffset {
        NightlyOffset(pairs: zip(apple, fitbit).map { ($0, $1) })!
    }

    func testSteadyRatioReadsAsAnOffset() {
        XCTAssertEqual(offset.typicalRatio, 0.77, accuracy: 0.02)
        XCTAssertGreaterThan(offset.correlation ?? 0, 0.9)
        XCTAssertEqual(
            offset.summary(other: "Fitbit", reference: "Apple"),
            "Fitbit reads ~23% lower than Apple, night after night — same trend, different scale."
        )
    }

    func testOnlyNightsThatBreakThePatternAreFlagged() {
        let flagged = zip(apple, fitbit).filter { offset.unusualDeviation(reference: $0, other: $1) != nil }
        XCTAssertTrue(flagged.isEmpty, "Every one of these nights sits within the usual band")
        // Apple 80 predicts Fitbit ~62; 50 is ~19% under that.
        XCTAssertEqual(offset.unusualDeviation(reference: 80, other: 50) ?? 0, -0.19, accuracy: 0.02)
        XCTAssertNil(offset.unusualDeviation(reference: nil, other: 50))
    }

    func testTooFewNightsHasNoTypicalGap() {
        XCTAssertNil(NightlyOffset(pairs: [(80, 60), (70, 52), (75, 58), (90, 70)]))
    }

    func testMatchingDevicesReadAsTheSame() {
        let same = NightlyOffset(pairs: [(60, 61), (70, 69), (80, 81), (65, 64), (75, 76)])!
        XCTAssertEqual(same.summary(other: "Fitbit", reference: "Apple"), "Fitbit and Apple read about the same, night after night.")
    }
}
