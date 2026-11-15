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

/// Fitbit's nightly HRV by wake day, cached so Compare can show it without a
/// network round trip.
///
/// These are health readings, so the cache is a file with complete data
/// protection, excluded from iCloud/Finder backups, and wiped on disconnect.
/// `url == nil` keeps it in memory (tests and the UI mock).
final class FitbitDailyHRVStore: @unchecked Sendable {
    /// Where builds before the file cache kept this; read once to clear it.
    static let legacyDefaultsKey = "airlift.fitbitDailyHRV"

    private let url: URL?
    private let lock = NSLock()
    private var memory: [String: FitbitDailyHRV] = [:]

    init(url: URL? = FitbitDailyHRVStore.defaultURL, legacyDefaults: UserDefaults? = nil) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([String: FitbitDailyHRV].self, from: data) {
            memory = stored
        }
        // The old cache sat in UserDefaults, which is backed up. Drop it; the
        // next sync refetches the nights into the protected file.
        legacyDefaults?.removeObject(forKey: Self.legacyDefaultsKey)
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Airlift", isDirectory: true)
            .appendingPathComponent("fitbit-daily-hrv.json")
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
            persist()
        }
    }

    /// Forgets every cached night — on disconnect, so nothing fetched from
    /// Google outlives the sign-in.
    func clear() {
        lock.withLock {
            memory = [:]
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Caller holds `lock`.
    private func persist() {
        guard var url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(memory).write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            Log.sync.error("Fitbit nightly HRV cache write failed: \(error.localizedDescription)")
        }
    }
}
