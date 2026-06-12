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
    /// delete-by-id re-sync.
    static let dataPointIDKey = "com.santekotturi.airlift.dataPointId"

    private let store: HKHealthStore
    private let sleepType = HKCategoryType(.sleepAnalysis)

    /// Stable device stamp so Health attributes the data to the Fitbit Air.
    private let device = HKDevice(
        name: "Fitbit Air",
        manufacturer: "Google",
        model: "Air",
        hardwareVersion: nil,
        firmwareVersion: nil,
        softwareVersion: nil,
        localIdentifier: nil,
        udiDeviceIdentifier: nil
    )

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Requests share + read access for sleep plus every bridged quantity metric
    /// (HR, resting HR, HRV, SpO2, respiratory rate, steps). One combined request
    /// so the user sees a single permissions sheet; the read side serves
    /// `HealthKitReader` (Apple Watch comparison data).
    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthKitError.notAvailable }
        let quantityTypes = MetricKind.allCases.map { HKQuantityType($0.hkIdentifier) }
        let share: Set<HKSampleType> = Set([sleepType] + quantityTypes)
        let read: Set<HKObjectType> = Set([sleepType] + quantityTypes)
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
                    HKMetadataKeySyncIdentifier: "airlift-\(kind.rawValue)-\(sample.id)",
                    HKMetadataKeySyncVersion: 1,
                ]
            )
        }
        try await store.save(hkSamples)
        Log.health.info("Wrote \(hkSamples.count) \(kind.rawValue) sample(s)")
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
