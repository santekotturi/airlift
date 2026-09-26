import Foundation
import HealthKit

/// Reads Apple Watch beat-to-beat series out of HealthKit.
///
/// The Watch records a short tachogram alongside each HRV reading — in a full
/// Health export every SDNN sample carries one, a median of 47 beats over 57 s.
/// `HKHeartbeatSeriesSample` is the public-API route to the same data, which is
/// what makes recomputing HRV possible on device instead of only in an export.
///
/// Two things are worth knowing before trusting the result:
///
/// * **Availability is not guaranteed.** The type is readable since iOS 13, but
///   whether the Watch persists series for its own HRV readings is not
///   documented. `probe(_:)` answers that empirically on a real device rather
///   than assuming either way — and every caller here degrades to "no Apple
///   RMSSD" rather than failing when the answer is no.
/// * **Density is unchanged.** Recomputing HRV does not create readings. The
///   Watch samples roughly every 2 hours asleep, so this yields ~4 tachograms a
///   night no matter how it is processed. That ceiling is the finding, not a
///   bug to engineer around.
final class HeartbeatSeriesReader: @unchecked Sendable {
    private let store: HKHealthStore

    static let seriesType = HKSeriesType.heartbeat()

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// What a device actually hands over — the answer the spike exists to get.
    struct Probe: Equatable {
        let isDataAvailable: Bool
        let authorization: HKAuthorizationStatus
        /// Series samples found in the probed window.
        let seriesCount: Int
        /// Beats across those series; zero with a non-zero `seriesCount` means
        /// the samples exist but their beats are withheld.
        let beatCount: Int
        /// Apple's own SDNN samples in the same window, for the ratio that
        /// matters: how many readings come with their raw material attached.
        let hrvSampleCount: Int

        var seriesPerHRVSample: Double? {
            hrvSampleCount > 0 ? Double(seriesCount) / Double(hrvSampleCount) : nil
        }

        /// Plain-language verdict for the UI and the log.
        var summary: String {
            guard isDataAvailable else { return "Health data is unavailable on this device." }
            switch authorization {
            case .notDetermined:
                return "Beat-to-beat access has not been requested yet."
            case .sharingDenied:
                // Read denial is indistinguishable from "no data" by design —
                // HealthKit hides the difference so apps cannot probe for it.
                return seriesCount == 0
                    ? "No beat-to-beat series came back. Either the Watch does not publish them or read access is off in Health › Sources › Airlift."
                    : "\(seriesCount) series, \(beatCount) beats."
            default:
                break
            }
            if seriesCount == 0 {
                return "No beat-to-beat series in this window — Apple HRV cannot be recomputed, so the comparison falls back to Apple's published SDNN."
            }
            if beatCount == 0 {
                return "\(seriesCount) series found but no beats returned."
            }
            let perSample = seriesPerHRVSample.map { String(format: " · %.2f per HRV reading", $0) } ?? ""
            return "\(seriesCount) series, \(beatCount) beats\(perSample)."
        }
    }

    var isDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// `.sharingDenied` here is not proof of denial: HealthKit deliberately
    /// reports read permission as denied-or-absent so an app cannot learn
    /// whether the user has data it was refused. Treat it as "may return
    /// nothing", never as an error to surface.
    var authorizationStatus: HKAuthorizationStatus {
        guard isDataAvailable else { return .notDetermined }
        return store.authorizationStatus(for: Self.seriesType)
    }

    /// One window's worth of series with their beats resolved.
    func tachograms(in interval: DateInterval) async throws -> [Tachogram] {
        let samples = try await seriesSamples(in: interval)
        var results: [Tachogram] = []
        for sample in samples {
            // Sequential on purpose: HealthKit streams each series through its
            // own long-lived query, and a night holds only a handful.
            let beats = try await beats(of: sample)
            guard beats.count > 1 else { continue }
            results.append(Tachogram(id: sample.uuid, start: sample.startDate, beats: beats))
        }
        return results.sorted { $0.start < $1.start }
    }

    /// Runs the availability question against real data.
    func probe(_ interval: DateInterval) async -> Probe {
        guard isDataAvailable else {
            return Probe(
                isDataAvailable: false, authorization: .notDetermined,
                seriesCount: 0, beatCount: 0, hrvSampleCount: 0
            )
        }
        let series = (try? await tachograms(in: interval)) ?? []
        let hrv = (try? await hrvSampleCount(in: interval)) ?? 0
        return Probe(
            isDataAvailable: true,
            authorization: authorizationStatus,
            seriesCount: series.count,
            beatCount: series.reduce(0) { $0 + $1.beats.count },
            hrvSampleCount: hrv
        )
    }

    // MARK: - Queries

    private func seriesSamples(in interval: DateInterval) async throws -> [HKHeartbeatSeriesSample] {
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end, options: []
        )
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: Self.seriesType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples?.compactMap { $0 as? HKHeartbeatSeriesSample } ?? [])
                }
            }
            store.execute(query)
        }
    }

    /// Streams one series' beats. The handler fires per beat and once more with
    /// `done`, so the continuation is guarded — a second resume would trap.
    private func beats(of sample: HKHeartbeatSeriesSample) async throws -> [Heartbeat] {
        let collector = BeatCollector()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKHeartbeatSeriesQuery(heartbeatSeries: sample) { _, timeSinceStart, precededByGap, done, error in
                if let error {
                    if collector.finish() { continuation.resume(throwing: error) }
                    return
                }
                if !done {
                    collector.append(
                        Heartbeat(timeSinceSeriesStart: timeSinceStart, precededByGap: precededByGap)
                    )
                }
                if done, collector.finish() {
                    continuation.resume(returning: collector.beats)
                }
            }
            store.execute(query)
        }
    }

    private func hrvSampleCount(in interval: DateInterval) async throws -> Int {
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end, options: []
        )
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRateVariabilitySDNN),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let ownBundleID = Bundle.main.bundleIdentifier
                    // Airlift's own imported Fitbit values live in this type
                    // too; only Apple's readings can carry beat series.
                    continuation.resume(returning: (samples ?? []).filter {
                        $0.sourceRevision.source.bundleIdentifier != ownBundleID
                    }.count)
                }
            }
            store.execute(query)
        }
    }
}

/// Accumulates streamed beats and hands out exactly one right to resume.
private final class BeatCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Heartbeat] = []
    private var finished = false

    var beats: [Heartbeat] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ beat: Heartbeat) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(beat)
    }

    /// True for the first caller only.
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}
