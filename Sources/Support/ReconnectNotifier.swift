import Foundation
import UserNotifications

/// Posts the one local notification Airlift needs: "your Google sign-in
/// expired."
///
/// In Testing-mode OAuth the refresh token dies roughly weekly. When that
/// happens during a background or launch sync there is no UI on screen —
/// without a notification the bridge stops silently and days of data quietly
/// pile up unsynced. Manual disconnects never notify; only an expired or
/// revoked sign-in discovered during a sync does.
protocol ReconnectNotifying: Sendable {
    /// Asks for notification permission. Called right after a successful
    /// connect — the moment the user's intent is clearest — instead of
    /// ambushing them on first launch.
    func requestAuthorization() async
    /// Posts (or refreshes) the reconnect notification. A stable identifier
    /// means repeated failing syncs re-surface one notification rather than
    /// stacking copies.
    func postReconnectNeeded() async
    /// Removes it once the user has reconnected.
    func clearReconnectNeeded() async
}

final class ReconnectNotifier: ReconnectNotifying {
    private static let identifier = "airlift.reconnect"

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.sync.notice("Notification authorization failed: \(error.localizedDescription)")
        }
    }

    func postReconnectNeeded() async {
        let content = UNMutableNotificationContent()
        content.title = "Reconnect to Google Health"
        content.body = "Your weekly Google sign-in expired — open Airlift to keep the bridge open."
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.sync.notice("Could not post reconnect notification: \(error.localizedDescription)")
        }
    }

    func clearReconnectNeeded() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }
}
