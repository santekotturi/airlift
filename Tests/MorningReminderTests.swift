import XCTest
@testable import Airlift

@MainActor
final class MorningReminderTests: XCTestCase {
    func testRunShortcutURLEncodesTheName() throws {
        let url = try XCTUnwrap(MorningReminder.runShortcutURL(named: "Sync Fitbit HRV"))
        XCTAssertEqual(url.absoluteString, "shortcuts://run-shortcut?name=Sync%20Fitbit%20HRV")
    }

    func testTriggerFiresAtTheChosenTimeEveryDay() {
        let components = MorningReminder.components(minutesAfterMidnight: 9 * 60 + 30)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 30)
        XCTAssertNil(components.day, "Only hour and minute, so it repeats daily")
    }

    func testDefaultsAreOffAtNineWithTheDocumentedShortcut() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MorningReminderTests"))
        defaults.removePersistentDomain(forName: "MorningReminderTests")
        let reminder = MorningReminder(defaults: defaults)
        XCTAssertFalse(reminder.isEnabled)
        XCTAssertEqual(reminder.minutesAfterMidnight, 540)
        XCTAssertEqual(reminder.shortcutName, "Sync Fitbit HRV")
    }
}
