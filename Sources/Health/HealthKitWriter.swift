import Foundation
import HealthKit

enum HealthKitError: Error, LocalizedError {
    case notAvailable
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "HealthKit is not available on this device."
        case .authorizationDenied: return "Permission to write sleep data was not granted."
        }
    }
}

/// Writes normalized `SleepSession`s into HealthKit.
///
/// Per the locked decision we write **per-stage** samples *and* one **`.inBed`**
/// sample spanning the whole session (matching how Apple Watch represents time in
/// bed vs. asleep). Every sample carries the originating Google dataPoint ID in
/// metadata so we can delete-then-rewrite when an upstream session is edited
/// (PRD §7/§8). HealthKit has no upsert, so the dedup store is the source of
/// truth for "already written" — this class only owns the write/delete mechanics.
final class HealthKitWriter: @unchecked Sendable {
    /// Custom metadata key carrying the Google dataPoint ID, for traceability and
    /// delete-by-id re-sync. A stable historical constant: changing it would
    /// orphan every sample already written (delete-by-ID and read-back both
    /// match on it), so it deliberately does not follow the bundle ID.
    static let dataPointIDKey = "com.santekotturi.airlift.dataPointId"

    private let store: HKHealthStore
    private let sleepType = HKCategoryType(.sleepAnalysis)
    private let lock = NSLock()
    private var _deviceName = DeviceLabel.fallback

    /// Stable device stamp so Health attributes the data to the user's
    /// Fitbit device. The name follows the engine's detected/override label;
    /// changing it only affects future writes (existing samples keep theirs).
    /// Lock-guarded — the `@unchecked Sendable` promise depends on it.
    var deviceName: String {
        get { lock.withLock { _deviceName } }
        set { lock.withLock { _deviceName = newValue } }
    }

    private var device: HKDevice {
        HKDevice(
            name: deviceName,
            manufacturer: "Google",
            model: nil,
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )
    }

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Requests share + read access for sleep plus every bridged quantity metric
    /// (HR, resting HR, HRV, SpO2, respiratory rate, steps). One combined request
    /// so the user sees a single permissions sheet; the read side serves
    /// `HealthKitReader` (Apple Watch comparison data).
    ///
    /// Beat-to-beat series are read-only and asked for here rather than in a
    /// second sheet later. They are what the Recovery screen recomputes Apple
    /// RMSSD from, so Fitbit's RMSSD has a like-for-like counterpart instead of
    /// being compared against Apple's SDNN.
    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthKitError.notAvailable }
        // SDNN is kept even after HRV moves to RMSSD: deleting Airlift's old
        // SDNN-typed HRV needs share permission for the type it lives in.
        let quantityTypes = (MetricKind.allCases.map(\.hkIdentifier) + [MetricKind.legacyHRVIdentifier])
            .map { HKQuantityType($0) }
        let share: Set<HKSampleType> = Set([sleepType] + quantityTypes)
        var read: Set<HKObjectType> = Set([sleepType, HeartbeatSeriesReader.seriesType] + quantityTypes)
        // Read-only: the Watch's own RMSSD, which the Recovery and HRV screens
        // compare with Fitbit's like for like.
        if let rmssd = MetricKind.rmssdIdentifier {
            read.insert(HKQuantityType(rmssd))
        }
        try await store.requestAuthorization(toShare: share, read: read)
    }

    /// Writes a batch of quantity samples for one metric. Dedup is the caller's
    /// job (skip IDs already imported); each sample carries its Google dataPoint
    /// ID in metadata, and a `HKMetadataKeySyncIdentifier` so HealthKit replaces
    /// (not duplicates) the sample if the same ID is ever re-imported.
    func write(_ samples: [MetricSample], kind: MetricKind) async throws {
        guard !samples.isEmpty else { return }
        let type = HKQuantityType(kind.hkIdentifier)
        let hkSamples = samples.map { sample in
            HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: kind.hkUnit, doubleValue: sample.value),
                start: sample.start,
                end: sample.end,
                device: device,
                metadata: [
                    Self.dataPointIDKey: sample.id,
                    HKMetadataKeySyncIdentifier: Self.syncIdentifier(kind: kind, dataPointID: sample.id),
                    HKMetadataKeySyncVersion: 1,
                ]
            )
        }
        try await store.save(hkSamples)
        Log.health.info("Wrote \(hkSamples.count) \(kind.rawValue) sample(s)")
    }

    /// HRV in the RMSSD type gets its own identifier scheme. HealthKit does not
    /// document whether sync identifiers are scoped per type or per source; a
    /// distinct one means a migrated copy can never be mistaken for — or
    /// replace — its SDNN original, whichever it is.
    static func syncIdentifier(kind: MetricKind, dataPointID: String) -> String {
        let isRMSSD = kind == .heartRateVariability && kind.hkIdentifier != MetricKind.legacyHRVIdentifier
        return isRMSSD
            ? "airlift-\(kind.rawValue)-rmssd-\(dataPointID)"
            : "airlift-\(kind.rawValue)-\(dataPointID)"
    }

    /// What a legacy-HRV migration did.
    struct HRVMigrationResult: Equatable {
        /// Airlift SDNN samples found.
        let found: Int
        /// RMSSD copies written this run (fewer than `found` when an earlier,
        /// interrupted run already wrote some).
        let written: Int
        /// SDNN originals deleted.
        let deleted: Int
    }

    enum HRVMigrationError: LocalizedError {
        case copiesMissing(expected: Int, found: Int)

        var errorDescription: String? {
            switch self {
            case .copiesMissing(let expected, let found):
                "Only \(found) of \(expected) RMSSD copies are in Apple Health, so the SDNN originals were left in place. Nothing was lost — try again."
            }
        }
    }

    /// How many of Airlift's HRV samples still sit in the SDNN type.
    @available(iOS 27.0, *)
    func legacyHRVCount() async throws -> Int {
        try await ownSamples(of: HKQuantityType(MetricKind.legacyHRVIdentifier)).count
    }

    /// Every source named like this app that holds SDNN samples, with counts —
    /// "bundle ID: n". Only the entry matching this build's bundle ID can be
    /// migrated; the others were written by a build under a different one.
    @available(iOS 27.0, *)
    func legacyHRVSources() async throws -> [String: Int] {
        let all: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(MetricKind.legacyHRVIdentifier),
                predicate: nil, limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownName = HealthKitReader.appDisplayName
        return all.reduce(into: [String: Int]()) { counts, sample in
            let source = sample.sourceRevision.source
            guard source.bundleIdentifier == ownBundleID || source.name == ownName else { return }
            counts[source.bundleIdentifier, default: 0] += 1
        }
    }

    /// Moves every Fitbit HRV sample Airlift wrote into SDNN — the only HRV
    /// type before iOS 27 — into the RMSSD type it always was.
    ///
    /// Copy, confirm, then delete: the RMSSD copies are saved first, the
    /// store is re-read to confirm every one of them is there, and only then
    /// are the SDNN originals deleted. An interruption at any point leaves the
    /// data in one type or both, never neither, and a re-run skips copies it
    /// already made. Copies keep the time, value, device and dataPoint ID, so
    /// the dedup store and ledger need no change, and take the RMSSD sync
    /// identifier a fresh write would, so a later re-import of the same point
    /// replaces the copy rather than duplicating it. Only this app's own samples are touched —
    /// `HKSource.default()` — never the Watch's.
    @available(iOS 27.0, *)
    func migrateLegacyHRV() async throws -> HRVMigrationResult {
        let legacyType = HKQuantityType(MetricKind.legacyHRVIdentifier)
        guard let rmssd = MetricKind.rmssdIdentifier else { return HRVMigrationResult(found: 0, written: 0, deleted: 0) }
        let rmssdType = HKQuantityType(rmssd)
        let unit = MetricKind.heartRateVariability.hkUnit

        let legacy = try await ownSamples(of: legacyType).compactMap { $0 as? HKQuantitySample }
        guard !legacy.isEmpty else { return HRVMigrationResult(found: 0, written: 0, deleted: 0) }

        func key(_ sample: HKSample) -> String {
            (sample.metadata?[Self.dataPointIDKey] as? String)
                ?? "\(sample.startDate.timeIntervalSince1970)|\(sample.endDate.timeIntervalSince1970)"
        }

        let alreadyCopied = Set(try await ownSamples(of: rmssdType).map(key))
        let copies = legacy.filter { !alreadyCopied.contains(key($0)) }.map { original in
            var metadata = original.metadata ?? [:]
            if let id = original.metadata?[Self.dataPointIDKey] as? String {
                metadata[HKMetadataKeySyncIdentifier] = Self.syncIdentifier(kind: .heartRateVariability, dataPointID: id)
                metadata[HKMetadataKeySyncVersion] = 1
            }
            return HKQuantitySample(
                type: rmssdType,
                quantity: HKQuantity(unit: unit, doubleValue: original.quantity.doubleValue(for: unit)),
                start: original.startDate,
                end: original.endDate,
                device: original.device ?? device,
                metadata: metadata
            )
        }
        for batch in stride(from: 0, to: copies.count, by: 500) {
            try await store.save(Array(copies[batch..<min(batch + 500, copies.count)]))
        }

        let copied = Set(try await ownSamples(of: rmssdType).map(key))
        let confirmed = legacy.filter { copied.contains(key($0)) }
        guard confirmed.count == legacy.count else {
            throw HRVMigrationError.copiesMissing(expected: legacy.count, found: confirmed.count)
        }
        for batch in stride(from: 0, to: confirmed.count, by: 500) {
            try await store.delete(Array(confirmed[batch..<min(batch + 500, confirmed.count)]))
        }
        Log.health.info("Migrated \(legacy.count) HRV sample(s) from SDNN to RMSSD (\(copies.count) newly written)")
        return HRVMigrationResult(found: legacy.count, written: copies.count, deleted: confirmed.count)
    }

    /// Every sample of `type` this app wrote, across all time.
    private func ownSamples(of type: HKSampleType) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForObjects(from: HKSource.default()),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    /// Writes one session (per-stage + `.inBed`). Any previously written samples
    /// for the same dataPoint ID are removed first, making re-writes idempotent.
    func write(_ session: SleepSession) async throws {
        try await deleteSamples(forDataPointID: session.id)

        var samples: [HKCategorySample] = session.stages.enumerated().map { index, segment in
            categorySample(
                value: StageMapper.healthKitValue(for: segment.stage),
                start: segment.start,
                end: segment.end,
                dataPointID: session.id,
                syncIdentifier: "airlift-sleep-\(session.id)#\(index)"
            )
        }

        // One .inBed sample spanning the full session.
        samples.append(
            categorySample(
                value: .inBed,
                start: session.start,
                end: session.end,
                dataPointID: session.id,
                syncIdentifier: "airlift-sleep-\(session.id)#inBed"
            )
        )

        try await store.save(samples)
        Log.health.info("Wrote \(samples.count) samples for session \(session.id)")
    }

    private func categorySample(
        value: HKCategoryValueSleepAnalysis,
        start: Date,
        end: Date,
        dataPointID: String,
        syncIdentifier: String
    ) -> HKCategorySample {
        HKCategorySample(
            type: sleepType,
            value: value.rawValue,
            start: start,
            end: end,
            device: device,
            metadata: [
                Self.dataPointIDKey: dataPointID,
                // HealthKit replaces (not duplicates) samples re-saved with the
                // same sync identifier — makes re-imports of edited sessions safe.
                HKMetadataKeySyncIdentifier: syncIdentifier,
                HKMetadataKeySyncVersion: 1,
            ]
        )
    }

    /// Deletes every Airlift-authored sample of `kind` (nil = sleep) whose
    /// civil day matches `interval` — quantities by start, sleep by wake
    /// (end). Returns the Google dataPoint IDs that were attached, so the
    /// caller can retire them and the data never re-stages. Queries first,
    /// then deletes the exact objects: a blanket predicate delete would also
    /// hit a session that merely *overlaps* the day from the night after.
    func deleteOwnSamples(kind: MetricKind?, in interval: DateInterval) async throws -> [String] {
        let type: HKSampleType = kind.map { HKQuantityType($0.hkIdentifier) } ?? sleepType
        let widened = kind == nil
            ? DateInterval(start: interval.start.addingTimeInterval(-86_400), end: interval.end)
            : interval
        let mine = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: widened.start, end: widened.end, options: []),
        ])
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: mine, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
        let anchored = samples.filter {
            kind == nil ? interval.contains($0.endDate) : interval.contains($0.startDate)
        }
        guard !anchored.isEmpty else { return [] }
        try await store.delete(anchored)
        return anchored.compactMap { $0.metadata?[Self.dataPointIDKey] as? String }
    }

    /// Deletes any Airlift-authored samples tagged with this dataPoint ID.
    /// Scoped to samples from *this* app via `HKQuery.predicateForObjects(from:)`
    /// so we never touch Apple Watch or other sources.
    private func deleteSamples(forDataPointID id: String) async throws {
        let mine = HKQuery.predicateForObjects(from: HKSource.default())
        let tagged = HKQuery.predicateForObjects(
            withMetadataKey: Self.dataPointIDKey,
            allowedValues: [id]
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [mine, tagged])

        do {
            try await store.deleteObjects(of: sleepType, predicate: predicate)
        } catch let error as HKError where error.code == .errorNoData {
            // Nothing to delete — fine.
        }
    }
}
