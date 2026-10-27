import XCTest
@testable import Airlift

final class WearOverlapTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func readings(from startHour: Double, to endHour: Double, every seconds: TimeInterval, value: Double) -> [WearOverlap.Reading] {
        stride(from: startHour * 3600, to: endHour * 3600, by: seconds).map {
            WearOverlap.Reading(date: base.addingTimeInterval($0), value: value)
        }
    }

    func testRunsSplitAtLongGaps() {
        let r = readings(from: 0, to: 2, every: 300, value: 60) + readings(from: 5, to: 6, every: 300, value: 60)
        XCTAssertEqual(WearOverlap.wornRuns(r).count, 2)
        XCTAssertEqual(WearOverlap.wornRuns(readings(from: 0, to: 4, every: 600, value: 60)).count, 1)
    }

    func testIntersection() {
        let a = [DateInterval(start: base, duration: 3600), DateInterval(start: base.addingTimeInterval(7200), duration: 3600)]
        let b = [DateInterval(start: base.addingTimeInterval(1800), duration: 7200)]
        let shared = WearOverlap.intersection(a, b)
        XCTAssertEqual(shared.map(\.duration), [1800, 1800])
    }

    func testTimeWeightingStopsAWorkoutBurstDominating() {
        // 2 h resting at 60, sampled every 5 min (24 readings), then a 30 min
        // workout at 150 sampled every 5 s (360 readings).
        let r = readings(from: 0, to: 2, every: 300, value: 60) + readings(from: 2, to: 2.5, every: 5, value: 150)
        let perSample = r.map(\.value).reduce(0, +) / Double(r.count)
        XCTAssertGreaterThan(perSample, 140)
        // ≈ (24·60 + 6·150) / 30; bucket edges shift it a little.
        XCTAssertEqual(WearOverlap.timeWeightedMean(r)!, 79, accuracy: 2)
    }

    /// The Oct 24 shape: Fitbit all day, Watch off its wrist 12:00–22:00 with
    /// a workout burst before. Only the shared hours count, time-weighted.
    func testWatchOffTheWristIsLeftOutOfTheComparison() {
        let google = readings(from: 0, to: 24, every: 60, value: 70)
        let apple = readings(from: 0, to: 9, every: 300, value: 72)
            + readings(from: 9, to: 11, every: 5, value: 74)
            + readings(from: 22, to: 24, every: 300, value: 72)
        let comparison = WearOverlap.compare(google: google, apple: apple)!
        XCTAssertEqual(comparison.google, 70, accuracy: 0.01)
        XCTAssertEqual(comparison.apple, 72.5, accuracy: 0.5)
        XCTAssertEqual(comparison.overlap / 3600, 13, accuracy: 0.2)
        let gap = comparison.longestAppleGap!
        XCTAssertEqual(gap.start.timeIntervalSince(base) / 3600, 11, accuracy: 0.01)
        XCTAssertEqual(gap.end.timeIntervalSince(base) / 3600, 22, accuracy: 0.01)
    }

    func testNoSharedWearIsNotComparable() {
        let google = readings(from: 0, to: 6, every: 60, value: 70)
        let apple = readings(from: 8, to: 12, every: 300, value: 90)
        XCTAssertNil(WearOverlap.compare(google: google, apple: apple))
    }

    func testHeartRateCheckPassesWhenTheWatchWasCharging() {
        let samples = readings(from: 0, to: 24, every: 60, value: 70).enumerated().map {
            MetricSample(id: "\($0.offset)", start: $0.element.date, end: $0.element.date.addingTimeInterval(60), value: $0.element.value)
        }
        // Watch: resting 9 h, a 2 h workout at 160 sampled every 5 s, then off.
        let apple = (readings(from: 0, to: 9, every: 300, value: 68) + readings(from: 9, to: 11, every: 5, value: 160)).map {
            QuantitySample(id: UUID(), start: $0.date, end: $0.date, value: $0.value)
        }
        let fitbitDuringWorkout = samples.map { s -> MetricSample in
            let hour = s.start.timeIntervalSince(base) / 3600
            return (9..<11).contains(hour) ? MetricSample(id: s.id, start: s.start, end: s.end, value: 155) : s
        }
        let checks = SanityChecks.runMetric(kind: .heartRate, samples: fitbitDuringWorkout, apple: apple)
        let comparison = checks.first { $0.name == "Apple comparison" }!
        XCTAssertEqual(comparison.severity, .pass, comparison.detail)
    }
}
