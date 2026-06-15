import XCTest
@testable import Airlift

/// HRV (and any `usesOvernightDay` metric) is attributed to a 6pm→6pm window
/// labelled by the wake day, so a night's readings never split at midnight.
final class OvernightWindowTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: - Grouping key

    func testEveningReadingGroupsIntoNextMorningsDay() {
        // 10pm Jun 10 is part of the night that wakes on Jun 11.
        let key = SyncEngine.metricDayKey(kind: .heartRateVariability, start: date(2026, 6, 10, 22), calendar: calendar)
        XCTAssertEqual(key, calendar.startOfDay(for: date(2026, 6, 11, 0)))
    }

    func testEarlyMorningReadingGroupsIntoSameDay() {
        let key = SyncEngine.metricDayKey(kind: .heartRateVariability, start: date(2026, 6, 11, 3), calendar: calendar)
        XCTAssertEqual(key, calendar.startOfDay(for: date(2026, 6, 11, 0)))
    }

    func testAcrossMidnightStaysOneNight() {
        let before = SyncEngine.metricDayKey(kind: .heartRateVariability, start: date(2026, 6, 10, 23, 30), calendar: calendar)
        let after = SyncEngine.metricDayKey(kind: .heartRateVariability, start: date(2026, 6, 11, 0, 30), calendar: calendar)
        XCTAssertEqual(before, after, "11:30pm and 12:30am of the same night must land on the same day")
    }

    func testSixPMIsTheBoundary() {
        // 6:00pm Jun 10 opens Jun 11's window; 5:59pm Jun 10 still closes Jun 10's.
        let opensNext = SyncEngine.metricDayKey(kind: .heartRateVariability, start: date(2026, 6, 10, 18, 0), calendar: calendar)
        let closesPrev = SyncEngine.metricDayKey(kind: .heartRateVariability, start: date(2026, 6, 10, 17, 59), calendar: calendar)
        XCTAssertEqual(opensNext, calendar.startOfDay(for: date(2026, 6, 11, 0)))
        XCTAssertEqual(closesPrev, calendar.startOfDay(for: date(2026, 6, 10, 0)))
    }

    func testNonOvernightMetricUsesCalendarDay() {
        let key = SyncEngine.metricDayKey(kind: .steps, start: date(2026, 6, 10, 22), calendar: calendar)
        XCTAssertEqual(key, calendar.startOfDay(for: date(2026, 6, 10, 0)), "steps stay on their civil day")
    }

    // MARK: - Interval

    func testOvernightIntervalSpansSixPMToSixPM() {
        let day = calendar.startOfDay(for: date(2026, 6, 11, 0))
        let interval = SyncEngine.metricDayInterval(kind: .heartRateVariability, day: day, calendar: calendar)
        XCTAssertEqual(interval.start, date(2026, 6, 10, 18))
        XCTAssertEqual(interval.end, date(2026, 6, 11, 18))
    }

    func testIntervalContainsTheWholeNight() {
        let day = calendar.startOfDay(for: date(2026, 6, 11, 0))
        let interval = SyncEngine.metricDayInterval(kind: .heartRateVariability, day: day, calendar: calendar)
        XCTAssertTrue(interval.contains(date(2026, 6, 10, 22)))
        XCTAssertTrue(interval.contains(date(2026, 6, 11, 5)))
        XCTAssertFalse(interval.contains(date(2026, 6, 11, 19)))
    }

    func testNonOvernightIntervalIsTheCivilDay() {
        let day = calendar.startOfDay(for: date(2026, 6, 11, 0))
        let interval = SyncEngine.metricDayInterval(kind: .steps, day: day, calendar: calendar)
        XCTAssertEqual(interval.start, day)
        XCTAssertEqual(interval.duration, 86_400, accuracy: 3_600) // ±DST hour
    }
}
