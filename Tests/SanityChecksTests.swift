import XCTest
import HealthKit
@testable import AirKit

final class SanityChecksTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    /// 8-hour session whose stages tile it perfectly.
    private func cleanSession(hours: Double = 8) -> SleepSession {
        let end = base.addingTimeInterval(hours * 3600)
        // Alternate light/deep/rem in 1h blocks covering the whole window.
        var stages: [SleepStageSegment] = []
        let cycle: [SleepStage] = [.light, .deep, .rem, .light]
        var cursor = base
        var i = 0
        while cursor < end {
            let next = min(cursor.addingTimeInterval(3600), end)
            stages.append(SleepStageSegment(stage: cycle[i % cycle.count], start: cursor, end: next))
            cursor = next
            i += 1
        }
        return SleepSession(id: "test", start: base, end: end, stages: stages)
    }

    private func appleSegments(start: Date, hours: Double) -> [AppleSleepSegment] {
        [AppleSleepSegment(
            id: UUID(),
            value: .asleepCore,
            start: start,
            end: start.addingTimeInterval(hours * 3600),
            sourceName: "Apple Watch"
        )]
    }

    // MARK: - Internal consistency

    func testCleanSessionPassesAllInternalChecks() {
        let results = SanityChecks.run(google: cleanSession(), appleSleep: [], heartRate: [])
        let internalChecks = results.filter { $0.name != "Apple Watch" }
        XCTAssertTrue(internalChecks.allSatisfy { $0.severity == .pass }, "\(internalChecks)")
    }

    func testTooShortSessionFails() {
        let result = SanityChecks.duration(cleanSession(hours: 0.2))
        XCTAssertEqual(result.severity, .fail)
    }

    func testMarathonSessionWarns() {
        let result = SanityChecks.duration(cleanSession(hours: 16))
        XCTAssertEqual(result.severity, .warn)
    }

    func testSegmentOutsideWindowFails() {
        var session = cleanSession()
        let rogue = SleepStageSegment(
            stage: .light,
            start: base.addingTimeInterval(-7200),
            end: base.addingTimeInterval(-3600)
        )
        session = SleepSession(id: session.id, start: session.start, end: session.end, stages: session.stages + [rogue])
        XCTAssertEqual(SanityChecks.segmentBounds(session).severity, .fail)
    }

    func testOverlappingSegmentsWarn() {
        let a = SleepStageSegment(stage: .light, start: base, end: base.addingTimeInterval(3600))
        let b = SleepStageSegment(stage: .deep, start: base.addingTimeInterval(1800), end: base.addingTimeInterval(5400))
        let session = SleepSession(id: "x", start: base, end: base.addingTimeInterval(5400), stages: [a, b])
        XCTAssertEqual(SanityChecks.segmentOverlap(session).severity, .warn)
    }

    func testSparseCoverageWarns() {
        // One 1h stage in an 8h session = 12.5% coverage.
        let only = SleepStageSegment(stage: .light, start: base, end: base.addingTimeInterval(3600))
        let session = SleepSession(id: "x", start: base, end: base.addingTimeInterval(8 * 3600), stages: [only])
        XCTAssertEqual(SanityChecks.stageCoverage(session).severity, .warn)
    }

    // MARK: - Apple comparison

    func testNoAppleDataIsInfoNotFailure() {
        let results = SanityChecks.appleComparison(google: cleanSession(), apple: [])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].severity, .info)
    }

    func testMatchingAppleNightPasses() {
        // Apple asleep 7.5h starting 15min after Google's 8h session.
        let apple = appleSegments(start: base.addingTimeInterval(900), hours: 7.5)
        let results = SanityChecks.appleComparison(google: cleanSession(), apple: apple)
        XCTAssertTrue(results.allSatisfy { $0.severity == .pass }, "\(results)")
    }

    func testDisjointAppleNightWarnsOnOverlap() {
        // Apple night 24h earlier — zero overlap → timezone-style bug.
        let apple = appleSegments(start: base.addingTimeInterval(-24 * 3600), hours: 8)
        let results = SanityChecks.appleComparison(google: cleanSession(), apple: apple)
        let overlap = results.first { $0.name == "Window overlap" }
        XCTAssertEqual(overlap?.severity, .warn)
    }

    func testLargeAsleepDeltaWarns() {
        // Apple says 3h asleep vs Google ~8h.
        let apple = appleSegments(start: base, hours: 3)
        let results = SanityChecks.appleComparison(google: cleanSession(), apple: apple)
        let delta = results.first { $0.name == "Asleep total" }
        XCTAssertEqual(delta?.severity, .warn)
    }

    func testInBedSegmentsDoNotCountAsAsleep() {
        let inBed = [AppleSleepSegment(id: UUID(), value: .inBed, start: base, end: base.addingTimeInterval(8 * 3600), sourceName: "Watch")]
        let results = SanityChecks.appleComparison(google: cleanSession(), apple: inBed)
        // Only .inBed → treated as "no Apple sleep data".
        XCTAssertEqual(results.first?.severity, .info)
    }

    // MARK: - Heart rate

    func testHeartRateSummaryComputed() {
        let hr = (0..<10).map { HRSample(id: UUID(), date: base.addingTimeInterval(Double($0) * 600), bpm: 50 + Double($0)) }
        let result = SanityChecks.heartRateSummary(google: cleanSession(), heartRate: hr)
        XCTAssertEqual(result?.severity, .info)
        XCTAssertTrue(result!.detail.contains("10 readings"))
    }

    func testHeartRateOutsideSessionIgnored() {
        let hr = [HRSample(id: UUID(), date: base.addingTimeInterval(-3600), bpm: 60)]
        XCTAssertNil(SanityChecks.heartRateSummary(google: cleanSession(), heartRate: hr))
    }
}
