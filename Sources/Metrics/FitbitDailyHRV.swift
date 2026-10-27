import Foundation

/// Fitbit's own nightly HRV — the number the Fitbit app shows for a night —
/// from Google Health's `daily-heart-rate-variability` type.
///
/// Airlift's 5-minute Fitbit RMSSD readings can be averaged into something
/// close, but Fitbit decides which readings count; this is its published
/// answer, so Compare shows it instead of a reconstruction. Never written to
/// Apple Health — HealthKit has no daily-summary type to hold it.
struct FitbitDailyHRV: Codable, Equatable, Sendable {
    /// The civil day Fitbit files the night under — the day you woke up —
    /// as `yyyy-MM-dd`.
    let day: String
    /// Fitbit's headline nightly HRV, ms.
    let average: Double
    /// RMSSD over deep sleep alone, ms, when Fitbit reports one.
    let deepSleepRMSSD: Double?
    /// Mean heart rate over non-REM sleep, bpm.
    let nonREMHeartRate: Double?
}

extension QuantityDataPointsResponse {
    /// The Fitbit's own daily points. Google also returns a daily value it
    /// derived from Apple Health (`platform: "HEALTH_KIT"`) — not Fitbit's
    /// number, so it is skipped.
    func fitbitDailyHRV() -> [FitbitDailyHRV] {
        (dataPoints ?? []).compactMap { point in
            guard point.dataSource?.platform == "FITBIT",
                  let payload = point.payloads["dailyHeartRateVariability"],
                  let year = payload.date?.year, let month = payload.date?.month, let day = payload.date?.day,
                  let average = payload.numerics["averageHeartRateVariabilityMilliseconds"], average > 0
            else { return nil }
            return FitbitDailyHRV(
                day: String(format: "%04d-%02d-%02d", year, month, day),
                average: average,
                // Zero is the wire's "not measured".
                deepSleepRMSSD: payload.numerics["deepSleepRootMeanSquareOfSuccessiveDifferencesMilliseconds"]
                    .flatMap { $0 > 0 ? $0 : nil },
                nonREMHeartRate: payload.numerics["nonRemHeartRateBeatsPerMinute"].flatMap { $0 > 0 ? $0 : nil }
            )
        }
    }

    /// Earliest civil day on the page, for paging back through time.
    var oldestDailyDate: Date? {
        (dataPoints ?? []).compactMap { $0.payloads.values.first?.date?.localDayStart }.min()
    }
}

/// Fitbit's nightly HRV by wake day. Persisted so Compare can show it
/// without a network round trip; `nil` defaults keeps it in memory (UI mock).
final class FitbitDailyHRVStore: @unchecked Sendable {
    private let defaults: UserDefaults?
    private let key = "airlift.fitbitDailyHRV"
    private let lock = NSLock()
    private var memory: [String: FitbitDailyHRV] = [:]

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: key),
           let stored = try? JSONDecoder().decode([String: FitbitDailyHRV].self, from: data) {
            memory = stored
        }
    }

    /// Fitbit's value for the night that ended on `wakeDay`.
    func value(forWakeDay wakeDay: Date) -> FitbitDailyHRV? {
        lock.withLock { memory[CivilDay.string(from: wakeDay)] }
    }

    /// Later fetches win: Fitbit can revise a night after more data syncs.
    func merge(_ values: [FitbitDailyHRV]) {
        guard !values.isEmpty else { return }
        lock.withLock {
            for value in values { memory[value.day] = value }
            if let defaults, let data = try? JSONEncoder().encode(memory) {
                defaults.set(data, forKey: key)
            }
        }
    }
}
