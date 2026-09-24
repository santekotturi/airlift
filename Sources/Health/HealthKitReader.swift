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
    /// False for sleep another app wrote — Google Health, once it writes Fitbit
    /// sleep into Health itself, would otherwise pass for the Watch's own.
    var fromAppleDevice: Bool = true

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
    var fromAppleDevice: Bool = true
}

/// A generic quantity reading from HealthKit (Apple-side comparison data),
/// already converted to the metric's HealthKit unit.
struct QuantitySample: Equatable, Hashable, Identifiable {
    let id: UUID
    let start: Date
    let end: Date
    let value: Double
    /// `HKMetadataKeyAlgorithmVersion`, when the writer set one.
    var algorithmVersion: Int? = nil
    var fromAppleDevice: Bool = true
    var sourceName: String? = nil

    /// Apple's HRV algorithm version 3 (watchOS 27, Ultra 4 hardware) reads
    /// HRV continuously in ~5-minute windows. Version 2 and earlier is the
    /// ~60-second spot check taken every couple of hours. The two share the
    /// SDNN type but not a meaning — a nightly mean across both would average a
    /// 60 s statistic with a 5 min one.
    static let continuousHRVAlgorithmVersion = 3

    var isContinuousHRV: Bool {
        (algorithmVersion ?? 0) >= Self.continuousHRVAlgorithmVersion
    }
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
                sourceName: category.sourceRevision.source.name,
                fromAppleDevice: Self.isAppleDevice(category.sourceRevision.source)
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
            return Self.quantitySample(quantity, unit: kind.hkUnit)
        }
    }

    /// RMSSD samples from every source except Airlift. The type only exists
    /// from iOS 27, where Apple Watch Ultra 4 writes it every ~5 minutes asleep;
    /// earlier systems get an empty array, not an error.
    ///
    /// Other apps may write it too (Google Health might, for Fitbit), so each
    /// sample carries `fromAppleDevice` for the caller to split on.
    func rmssdSamples(in interval: DateInterval) async throws -> [QuantitySample] {
        guard #available(iOS 27.0, *) else { return [] }
        let samples = try await querySamples(
            type: HKQuantityType(.heartRateVariabilityRMSSD),
            interval: interval
        )
        let ownBundleID = Bundle.main.bundleIdentifier
        let unit = HKUnit.secondUnit(with: .milli)
        return samples.compactMap { sample -> QuantitySample? in
            guard
                let quantity = sample as? HKQuantitySample,
                quantity.sourceRevision.source.bundleIdentifier != ownBundleID
            else { return nil }
            return Self.quantitySample(quantity, unit: unit)
        }
    }

    private static func quantitySample(_ quantity: HKQuantitySample, unit: HKUnit) -> QuantitySample {
        let version = quantity.metadata?[HKMetadataKeyAlgorithmVersion]
        return QuantitySample(
            id: quantity.uuid,
            start: quantity.startDate,
            end: quantity.endDate,
            value: quantity.quantity.doubleValue(for: unit),
            algorithmVersion: (version as? NSNumber)?.intValue ?? (version as? String).flatMap { Int($0) },
            fromAppleDevice: isAppleDevice(quantity.sourceRevision.source),
            sourceName: quantity.sourceRevision.source.name
        )
    }

    /// True for data an Apple Watch or iPhone recorded itself. Their sources are
    /// all `com.apple.health.<device UUID>`; any other app's bundle ID is its own.
    static func isAppleDevice(_ source: HKSource) -> Bool {
        source.bundleIdentifier.hasPrefix("com.apple.health")
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

    /// One Airlift-authored sample read back from Health — the calendar's
    /// day view lists these, and the attached Google dataPoint ID (written as
    /// metadata) lets a deletion also retire the ID so the data never
    /// re-stages.
    struct OwnSample: Equatable, Identifiable {
        let id: UUID
        let start: Date
        let end: Date
        /// Quantity value in the kind's `hkUnit`; sleep stage raw value for
        /// sleep samples.
        let value: Double
        let dataPointID: String?
    }

    /// Samples this app imported, matched by bundle ID *or* by source name.
    ///
    /// For read-only analysis only — never for dedup or deletion, which must
    /// stay strictly bundle-ID scoped so the app can only ever retire samples
    /// it provably wrote.
    ///
    /// The looser match exists because a rebuild under a different bundle ID —
    /// a re-clone, a fresh `Config.xcconfig`, a change of team — makes every
    /// previously imported night invisible to `ownQuantitySamples`, and the
    /// analysis screens then report "no Fitbit data" about data plainly sitting
    /// in Health. HealthKit keeps the source *name* across such a change, so it
    /// is the more durable handle on "this came from Airlift".
    func importedQuantitySamples(_ kind: MetricKind, in interval: DateInterval) async throws -> [OwnSample] {
        let samples = try await querySamples(
            type: HKQuantityType(kind.hkIdentifier),
            interval: interval
        )
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownName = Self.appDisplayName
        return samples.compactMap { sample -> OwnSample? in
            guard
                let quantity = sample as? HKQuantitySample,
                interval.contains(quantity.startDate)
            else { return nil }
            let source = quantity.sourceRevision.source
            guard source.bundleIdentifier == ownBundleID || source.name == ownName else { return nil }
            return OwnSample(
                id: quantity.uuid,
                start: quantity.startDate,
                end: quantity.endDate,
                value: quantity.quantity.doubleValue(for: kind.hkUnit),
                dataPointID: quantity.metadata?[HealthKitWriter.dataPointIDKey] as? String
            )
        }
    }

    /// Sleep samples this app imported, on the same bundle-ID-or-name rule as
    /// `importedQuantitySamples`, and read-only for the same reason.
    func importedSleepSamples(endingIn interval: DateInterval) async throws -> [OwnSample] {
        let widened = DateInterval(start: interval.start.addingTimeInterval(-86_400), end: interval.end)
        let samples = try await querySamples(type: HKCategoryType(.sleepAnalysis), interval: widened)
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownName = Self.appDisplayName
        return samples.compactMap { sample -> OwnSample? in
            guard
                let category = sample as? HKCategorySample,
                interval.contains(category.endDate)
            else { return nil }
            let source = category.sourceRevision.source
            guard source.bundleIdentifier == ownBundleID || source.name == ownName else { return nil }
            return OwnSample(
                id: category.uuid,
                start: category.startDate,
                end: category.endDate,
                value: Double(category.value),
                dataPointID: category.metadata?[HealthKitWriter.dataPointIDKey] as? String
            )
        }
    }

    /// The name HealthKit files this app's samples under.
    static let appDisplayName: String = {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "Airlift"
    }()

    /// Airlift-authored quantity samples whose *start* falls inside
    /// `interval` — matches how batches are grouped into civil days.
    func ownQuantitySamples(_ kind: MetricKind, in interval: DateInterval) async throws -> [OwnSample] {
        let samples = try await querySamples(
            type: HKQuantityType(kind.hkIdentifier),
            interval: interval
        )
        let ownBundleID = Bundle.main.bundleIdentifier
        return samples.compactMap { sample -> OwnSample? in
            guard
                let quantity = sample as? HKQuantitySample,
                quantity.sourceRevision.source.bundleIdentifier == ownBundleID,
                interval.contains(quantity.startDate)
            else { return nil }
            return OwnSample(
                id: quantity.uuid,
                start: quantity.startDate,
                end: quantity.endDate,
                value: quantity.quantity.doubleValue(for: kind.hkUnit),
                dataPointID: quantity.metadata?[HealthKitWriter.dataPointIDKey] as? String
            )
        }
    }

    /// Airlift-authored sleep samples whose *end* (wake) falls inside
    /// `interval` — "Tuesday's sleep" is the night that ended Tuesday morning.
    func ownSleepSamples(endingIn interval: DateInterval) async throws -> [OwnSample] {
        // Query a widened window so a long session still overlaps, then trim
        // to wake-day precisely.
        let widened = DateInterval(start: interval.start.addingTimeInterval(-86_400), end: interval.end)
        let samples = try await querySamples(type: HKCategoryType(.sleepAnalysis), interval: widened)
        let ownBundleID = Bundle.main.bundleIdentifier
        return samples.compactMap { sample -> OwnSample? in
            guard
                let category = sample as? HKCategorySample,
                category.sourceRevision.source.bundleIdentifier == ownBundleID,
                interval.contains(category.endDate)
            else { return nil }
            return OwnSample(
                id: category.uuid,
                start: category.startDate,
                end: category.endDate,
                value: Double(category.value),
                dataPointID: category.metadata?[HealthKitWriter.dataPointIDKey] as? String
            )
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
                bpm: quantity.quantity.doubleValue(for: bpmUnit),
                fromAppleDevice: Self.isAppleDevice(quantity.sourceRevision.source)
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
