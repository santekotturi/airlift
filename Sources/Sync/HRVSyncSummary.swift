import Foundation
import UserNotifications

/// What the "Sync New Data" shortcut tells you when it finishes: last night's
/// HRV, as it landed — or why it did not.
///
/// The morning automation runs with the phone in hand but Airlift closed, so
/// without this the only sign it worked is a Shortcuts banner that says an
/// automation ran, not what it found. A night Google had nothing for is worth
/// a notification too: it usually means the band had not uploaded yet.
struct HRVSyncSummary: Equatable {
    let title: String
    let body: String

    enum Outcome: Equatable {
        /// Written to Apple Health on its own (Automatic mode, checks passed).
        case imported
        /// Staged but held back by a check (Automatic mode).
        case held
        /// Staged for review (Review everything mode).
        case awaitingReview
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// - Parameter batch: the newest HRV night this run staged, or nil when
    ///   Google had nothing new.
    static func make(
        batch: StagedMetricBatch?,
        outcome: Outcome,
        fitbitName: String,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> HRVSyncSummary {
        if case .failed(let message) = outcome {
            return HRVSyncSummary(title: "Airlift couldn't sync", body: message)
        }
        guard let batch, !batch.samples.isEmpty else {
            return HRVSyncSummary(
                title: "No new HRV from Fitbit",
                body: "Nothing new since the last sync. If last night is missing, the band may not have uploaded yet — open Google Health, then run Sync New Data again."
            )
        }

        let night = nightName(batch.day, calendar: calendar, now: now)
        let fitbit = "\(fitbitName): \(ms(mean(batch.samples.map(\.value)))) across \(batch.samples.count) readings"

        switch outcome {
        case .imported:
            let apple: String
            if let appleMean = mean(batch.appleSamples.map(\.value)) {
                let device = batch.appleDeviceLabel ?? "Apple Watch"
                let statistic = batch.appleStatistic.map { " \($0)" } ?? ""
                apple = "\(device)\(statistic): \(ms(appleMean))."
            } else {
                apple = "No Apple Watch HRV for that night."
            }
            return HRVSyncSummary(title: "\(night) HRV is in Apple Health", body: "\(fitbit). \(apple)")
        case .held:
            let flagged = batch.checks.first { $0.severity == .warn || $0.severity == .fail }
            let reason = flagged.map { " — held back: \($0.detail)" } ?? ""
            return HRVSyncSummary(
                title: "\(night) HRV is waiting for you",
                body: "\(fitbit)\(reason). Open Airlift to review it."
            )
        case .awaitingReview:
            return HRVSyncSummary(
                title: "\(night) HRV is ready to review",
                body: "\(fitbit). Open Airlift to add it to Apple Health."
            )
        case .failed:
            preconditionFailure("handled above")
        }
    }

    /// HRV days are keyed by the morning the night wakes into, so the night
    /// itself is named by the evening before: "Last night's", "Tuesday night's".
    private static func nightName(_ wakeDay: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(wakeDay, inSameDayAs: now) { return "Last night's" }
        let evening = calendar.date(byAdding: .day, value: -1, to: wakeDay) ?? wakeDay
        let weekday = evening.formatted(Date.FormatStyle(calendar: calendar).weekday(.wide))
        return "\(weekday) night's"
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func ms(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "—"
    }

    /// Posts it, replacing the previous morning's rather than stacking. Silent
    /// when notifications are off — the shortcut's own dialog still says it —
    /// and when it would repeat the last one word for word: a night still held,
    /// or the same error, on a trigger that fires every time an app opens.
    static func post(_ summary: HRVSyncSummary, defaults: UserDefaults = .standard) async {
        let key = "airlift.lastHRVSummary"
        let fingerprint = "\(summary.title)\n\(summary.body)"
        guard defaults.string(forKey: key) != fingerprint else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        defaults.set(fingerprint, forKey: key)
        let content = UNMutableNotificationContent()
        content.title = summary.title
        content.body = summary.body
        let request = UNNotificationRequest(identifier: "airlift.hrv-summary", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            Log.sync.notice("Could not post HRV summary: \(error.localizedDescription)")
        }
    }
}
