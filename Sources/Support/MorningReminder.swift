import Foundation
import UIKit
import UserNotifications

/// A daily notification that, when tapped, runs the user's sync shortcut.
///
/// Built for people who stop their alarm on an Apple Watch: an alarm-triggered
/// automation then runs on a locked phone, where it can neither open Google
/// Health (to make the band upload) nor read HealthKit (Airlift's comparison
/// checks). Tapping a notification unlocks the phone by construction. Airlift
/// hands off to Shortcuts rather than doing the steps itself because opening
/// Google Health would suspend Airlift mid-flow; a shortcut keeps running
/// across the app switch: Open Google Health → Wait → Sync New Data.
@MainActor
final class MorningReminder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MorningReminder()

    nonisolated static let identifier = "airlift.morning-reminder"
    static let defaultShortcutName = "Sync Fitbit HRV"

    private enum Key {
        static let enabled = "airlift.morningReminder.enabled"
        static let minutes = "airlift.morningReminder.minutes"
        static let shortcut = "airlift.morningReminder.shortcut"
    }

    private let defaults: UserDefaults
    /// Set by a tap that arrived before the app was active; run on activation.
    private var pendingShortcut: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Minutes after midnight; 9:00 until changed.
    var minutesAfterMidnight: Int {
        get { defaults.object(forKey: Key.minutes) as? Int ?? 9 * 60 }
        set { defaults.set(newValue, forKey: Key.minutes) }
    }

    var shortcutName: String {
        get { defaults.string(forKey: Key.shortcut) ?? Self.defaultShortcutName }
        set { defaults.set(newValue, forKey: Key.shortcut) }
    }

    /// Becomes the notification delegate. Must run during launch so a tap that
    /// cold-starts the app is still delivered.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Replaces the scheduled reminder with one matching the current settings,
    /// or removes it when off.
    func reschedule() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        guard isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Sync last night's HRV"
        content.body = "Tap to open Google Health and bring last night's Fitbit HRV into Apple Health."
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Self.components(minutesAfterMidnight: minutesAfterMidnight),
            repeats: true
        )
        do {
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
        } catch {
            Log.sync.notice("Could not schedule morning reminder: \(error.localizedDescription)")
        }
    }

    static func components(minutesAfterMidnight: Int) -> DateComponents {
        DateComponents(hour: minutesAfterMidnight / 60, minute: minutesAfterMidnight % 60)
    }

    /// `shortcuts://run-shortcut?name=…` — runs a shortcut by name, or shows
    /// Shortcuts' own "not found" if it has been renamed.
    static func runShortcutURL(named name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    /// Runs a shortcut a tap asked for, once the app is in the foreground —
    /// opening another app's URL during launch is not reliable.
    func runPendingShortcut() {
        guard
            let name = pendingShortcut,
            UIApplication.shared.applicationState == .active,
            let url = Self.runShortcutURL(named: name)
        else { return }
        pendingShortcut = nil
        UIApplication.shared.open(url)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == Self.identifier,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        await MainActor.run {
            pendingShortcut = shortcutName
            runPendingShortcut()
        }
    }

    /// Airlift's notifications still show while it is open — the HRV summary
    /// posted by a shortcut run can land while Airlift is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
