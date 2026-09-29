import HealthKit
import XCTest
@testable import Airlift

/// The night that read as 16 hours: the Watch's ~8 h plus Google Health's copy
/// of Fitbit's ~8 h, summed as if both were the Watch.
final class SleepNightMatcherTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    private func segment(
        _ value: HKCategoryValueSleepAnalysis, _ from: Double, _ to: Double,
        apple: Bool = true, google: Bool = false, externalID: String? = nil
    ) -> AppleSleepSegment {
        AppleSleepSegment(
            id: UUID(), value: value, start: at(from), end: at(to),
            sourceName: google ? "Google Health" : (apple ? "Apple Watch" : "WHOOP"),
            fromAppleDevice: apple, fromGoogleHealth: google, externalID: externalID
        )
    }

    private var session: DateInterval { DateInterval(start: at(0), end: at(8)) }

    func testAppleNightExcludesOtherAppsSleep() {
        let segments = [
            segment(.asleepCore, 0, 4), segment(.asleepDeep, 4, 8),
            segment(.asleepCore, 0, 8, apple: false, google: true, externalID: "night-1"),
            segment(.asleepCore, 0, 8, apple: false),
        ]
        let night = SleepNightMatcher.appleNight(segments, matching: session)
        XCTAssertEqual(night.count, 2)
        XCTAssertTrue(night.allSatisfy(\.fromAppleDevice))
        XCTAssertEqual(night.filter(\.isAsleep).reduce(0) { $0 + $1.duration } / 3600, 8, accuracy: 0.01)
    }

    func testAppleNightDropsAnEveningNapInsideTheQueryWindow() {
        let segments = [
            segment(.asleepCore, -5, -4),          // nap, 4 h before bed
            segment(.asleepCore, 0, 3), segment(.awake, 3, 3.2), segment(.asleepREM, 3.2, 8),
        ]
        let night = SleepNightMatcher.appleNight(segments, matching: session)
        XCTAssertEqual(night.count, 3)
        XCTAssertFalse(night.contains { $0.start == at(-5) })
    }

    func testAppleNightFallsBackToNearestWhenShifted() {
        let segments = [segment(.asleepCore, 9, 16)]
        XCTAssertEqual(SleepNightMatcher.appleNight(segments, matching: session).count, 1)
    }

    func testGoogleHealthCopyMatchedByExternalID() {
        let segments = [segment(.asleepCore, 0, 1, apple: false, google: true, externalID: "night-1")]
        XCTAssertTrue(SleepNightMatcher.googleHealthWrote(sessionID: "night-1", session: session, in: segments))
    }

    func testAdjacentNightFromGoogleHealthDoesNotCount() {
        let segments = [segment(.asleepCore, 0, 8, apple: false, google: true, externalID: "night-0")]
        XCTAssertFalse(SleepNightMatcher.googleHealthWrote(sessionID: "night-1", session: session, in: segments))
    }

    func testUntaggedGoogleHealthSleepMatchesByOverlap() {
        let covering = [segment(.asleepCore, 0, 6, apple: false, google: true)]
        let sliver = [segment(.asleepCore, 0, 1, apple: false, google: true)]
        XCTAssertTrue(SleepNightMatcher.googleHealthWrote(sessionID: "x", session: session, in: covering))
        XCTAssertFalse(SleepNightMatcher.googleHealthWrote(sessionID: "x", session: session, in: sliver))
    }

    func testOtherTrackersNeverCountAsGoogleHealth() {
        let segments = [segment(.asleepCore, 0, 8, apple: false)]
        XCTAssertFalse(SleepNightMatcher.googleHealthWrote(sessionID: "x", session: session, in: segments))
    }

    func testMainNightPicksTheLongestSleep() {
        let segments = [segment(.asleepCore, -6, -5), segment(.asleepCore, 0, 7)]
        XCTAssertEqual(SleepNightMatcher.mainNight(segments).first?.start, at(0))
    }
}
