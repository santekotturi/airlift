import Foundation
import HealthKit

/// A sleep-analysis sample read back from HealthKit — typically Apple Watch data
/// used as the trusted reference when validating Google sessions.
struct AppleSleepSegment: Equatable, Hashable, Identifiable {
    let id: UUID
    let value: HKCategoryValueSleepAnalysis
    let start: Date
    let end: Date
    let sourceName: String

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// True for any actually-asleep stage (excludes `.inBed` and `.awake`).
    var isAsleep: Bool {
        switch value {
        case .asleepCore, .asleepDeep, .asleepREM, .asleepUnspecified: return true
        default: return false
        }
    }
}

/// One heart-rate reading.
struct HRSample: Equatable, Hashable, Identifiable {
    let id: UUID
    let date: Date
    let bpm: Double
}

/// A generic quantity reading from HealthKit (Apple-side comparison data),
/// already converted to the metric's HealthKit unit.
struct QuantitySample: Equatable, Hashable, Identifiable {
    let id: UUID
    let start: Date
    let end: Date
    let value: Double
}

/// Reads existing HealthKit data (Apple Watch sleep + heart rate) so Google
/// sessions can be compared against a trusted reference before import.
final class HealthKitReader: @unchecked Sendable {
    private let store: HKHealthStore

    init(store: HKHealthStore) {
        self.store = store
    }

    /// Sleep samples overlapping `interval`, from sources *other than Airlift* —
    /// previously imported sessions must never validate themselves.
    func sleepSegments(overlapping interval: DateInterval) async throws -> [AppleSleepSegment] {
        let samples = try await querySamples(
            type: HKCategoryType(.sleepAnalysis),
            interval: interval
        )
        let ownBundleID = Bundle.main.bundleIdentifier
        return samples.compactMap { sample -> AppleSleepSegment? in
            guard
                let category = sample as? HKCategorySample,
                category.sourceRevision.source.bundleIdentifier != ownBundleID,
                let value = HKCategoryValueSleepAnalysis(rawValue: category.value)
            else { return nil }
            return AppleSleepSegment(
                id: category.uuid,
                value: value,
                start: category.startDate,
                end: category.endDate,
                sourceName: category.sourceRevision.source.name
            )
        }
    }

    /// Quantity samples of one bridged metric within `interval`, from sources
    /// other than Airlift, in the metric's HealthKit unit.
    func quantitySamples(_ kind: MetricKind, in interval: DateInterval) async throws -> [QuantitySample] {
        let samples = try await querySamples(
            type: HKQuantityType(kind.hkIdentifier),
            interval: interval
        )
        let ownBundleID = Bundle.main.bundleIdentifier
        return samples.compactMap { sample -> QuantitySample? in
            guard
                let quantity = sample as? HKQuantitySample,
                quantity.sourceRevision.source.bundleIdentifier != ownBundleID
            else { return nil }
            return QuantitySample(
                id: quantity.uuid,
                start: quantity.startDate,
                end: quantity.endDate,
                value: quantity.quantity.doubleValue(for: kind.hkUnit)
            )
        }
    }

    /// Sum of one cumulative metric over `interval` from sources other than
    /// Airlift, via a statistics query — HealthKit deduplicates overlapping
    /// iPhone + Watch samples the same way the Health app's totals do, which
    /// naively summing samples does not.
    func cumulativeTotal(_ kind: MetricKind, in interval: DateInterval) async throws -> Double {
        let type = HKQuantityType(kind.hkIdentifier)
        let ownBundleID = Bundle.main.bundleIdentifier
        let others = try await sources(for: type).filter { $0.bundleIdentifier != ownBundleID }
        guard !others.isEmpty else { return 0 }

        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: []),
            HKQuery.predicateForObjects(from: Set(others)),
        ])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: kind.hkUnit) ?? 0)
                }
            }
            store.execute(query)
        }
    }

    /// Hourly deduplicated sums for a cumulative metric, for charting against
    /// Google's hourly buckets — same source-exclusion and deduplication rules
    /// as `cumulativeTotal`.
    func hourlyTotals(_ kind: MetricKind, in interval: DateInterval) async throws -> [QuantitySample] {
        let type = HKQuantityType(kind.hkIdentifier)
        let ownBundleID = Bundle.main.bundleIdentifier
        let others = try await sources(for: type).filter { $0.bundleIdentifier != ownBundleID }
        guard !others.isEmpty else { return [] }

        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: []),
            HKQuery.predicateForObjects(from: Set(others)),
        ])
        let collection: HKStatisticsCollection? = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: interval.start,
                intervalComponents: DateComponents(hour: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: collection)
                }
            }
            store.execute(query)
        }

        var totals: [QuantitySample] = []
        collection?.enumerateStatistics(from: interval.start, to: interval.end) { stats, _ in
            let value = stats.sumQuantity()?.doubleValue(for: kind.hkUnit) ?? 0
            if value > 0 {
                totals.append(QuantitySample(id: UUID(), start: stats.startDate, end: stats.endDate, value: value))
            }
        }
        return totals
    }

    private func sources(for type: HKSampleType) async throws -> Set<HKSource> {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sources, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: sources ?? [])
                }
            }
            store.execute(query)
        }
    }

    /// Heart-rate readings within `interval`, ascending by time.
    func heartRate(in interval: DateInterval) async throws -> [HRSample] {
        let samples = try await querySamples(
            type: HKQuantityType(.heartRate),
            interval: interval
        )
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        return samples.compactMap { sample -> HRSample? in
            guard let quantity = sample as? HKQuantitySample else { return nil }
            return HRSample(
                id: quantity.uuid,
                date: quantity.startDate,
                bpm: quantity.quantity.doubleValue(for: bpmUnit)
            )
        }
    }

    private func querySamples(type: HKSampleType, interval: DateInterval) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start,
            end: interval.end,
            options: []
        )
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
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
}
