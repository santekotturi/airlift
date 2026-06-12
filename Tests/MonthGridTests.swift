import XCTest
@testable import Airlift

final class MonthGridTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.firstWeekday = 1 // Sunday
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testJune2026LaysOutCorrectly() {
        // June 1, 2026 is a Monday → one leading nil under a Sunday-first week.
        let cells = MonthGrid.cells(for: date(2026, 6, 15), calendar: calendar)
        XCTAssertEqual(cells.count, 1 + 30)
        XCTAssertNil(cells[0])
        XCTAssertEqual(cells[1], date(2026, 6, 1))
        XCTAssertEqual(cells.last!, date(2026, 6, 30))
    }

    func testMonthStartingOnFirstWeekdayHasNoPadding() {
        // February 2026 starts on Sunday.
        let cells = MonthGrid.cells(for: date(2026, 2, 10), calendar: calendar)
        XCTAssertEqual(cells.first!, date(2026, 2, 1))
        XCTAssertEqual(cells.count, 28)
    }

    func testMondayFirstCalendarShiftsPadding() {
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2
        // June 1, 2026 is a Monday → zero leading nils.
        let cells = MonthGrid.cells(for: date(2026, 6, 1), calendar: mondayFirst)
        XCTAssertEqual(cells.first!, date(2026, 6, 1))
        XCTAssertEqual(MonthGrid.weekdaySymbols(calendar: mondayFirst).first, mondayFirst.veryShortStandaloneWeekdaySymbols[1])
    }

    func testEveryCellBelongsToTheMonth() {
        let cells = MonthGrid.cells(for: date(2026, 12, 25), calendar: calendar).compactMap { $0 }
        XCTAssertEqual(cells.count, 31)
        XCTAssertTrue(cells.allSatisfy { calendar.component(.month, from: $0) == 12 })
    }
}
