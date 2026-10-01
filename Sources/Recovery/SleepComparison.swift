import Foundation
import HealthKit

/// Minutes in each stage of one device's night.
///
/// Counted minute by minute rather than by summing segment durations, so two
/// overlapping samples (two watches, a re-scored night written twice) cannot
/// make a night longer than the time it spans. Where samples overlap the later
/// one wins, as in `SleepAgreement`.
struct StageMinutes: Equatable {
    var deep: Double = 0
    var rem: Double = 0
    var core: Double = 0
    /// Asleep without a stage — classic Fitbit logs, Apple's `asleepUnspecified`.
    var unspecified: Double = 0
    var awake: Double = 0
    let start: Date
    let end: Date

    var asleep: Double { deep + rem + core + unspecified }

    init?(_ spans: [(stage: SleepAgreement.Stage, start: Date, end: Date)]) {
        guard
            let start = spans.map(\.start).min(),
            let end = spans.map(\.end).max(),
            end > start
        else { return nil }
        self.start = start
        self.end = end
        var cursor = start.addingTimeInterval(30)
        while cursor < end {
            defer { cursor.addTimeInterval(60) }
            guard let stage = spans.last(where: { cursor >= $0.start && cursor < $0.end })?.stage else { continue }
            switch stage {
            case .deep: deep += 1
            case .rem: rem += 1
            case .core: core += 1
            case .asleep: unspecified += 1
            case .awake: awake += 1
            }
        }
    }
}

/// What the Sleep screen charts and averages.
enum SleepMeasure: String, CaseIterable, Identifiable {
    case total, deep, rem, core, awake

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .total: "Total sleep"
        case .deep: "Deep"
        case .rem: "REM"
        case .core: "Light / core"
        case .awake: "Awake"
        }
    }

    func minutes(_ night: StageMinutes) -> Double {
        switch self {
        case .total: night.asleep
        case .deep: night.deep
        case .rem: night.rem
        case .core: night.core
        case .awake: night.awake
        }
    }
}

/// One night as each device scored it.
struct SleepNightComparison: Identifiable, Equatable {
    var id: Date { night }

    let night: Date
    let watchSegments: [AppleSleepSegment]
    let fitbitSegments: [SleepStageSegment]
    let watch: StageMinutes?
    let fitbit: StageMinutes?
    /// Minute-by-minute stage agreement, percent — nil unless both scored it.
    let agreement: Double?
    /// "Watch Ultra 4", from the source that wrote the night.
    let watchDevice: String?

    var isPaired: Bool { watch != nil && fitbit != nil }
}

/// The Watch and Fitbit, night by night and on average, over whatever nights
/// the Recovery engine read.
struct SleepComparisonReport: Equatable {
    struct Summary: Equatable {
        let nights: Int
        let watchMean: Double
        let fitbitMean: Double
        /// Mean of (Fitbit − Watch), minutes.
        let meanDifference: Double
        /// Spread of that difference night to night — how far any one night's
        /// gap can be trusted.
        let differenceSD: Double?
        /// Rank agreement across nights: do the two devices agree on which
        /// nights had more?
        let spearman: Double?
    }

    let nights: [SleepNightComparison]

    static let empty = SleepComparisonReport(nights: [])

    var paired: [SleepNightComparison] { nights.filter(\.isPaired) }

    var medianAgreement: Double? { RecoveryStats.median(paired.compactMap(\.agreement)) }

    func summary(_ measure: SleepMeasure) -> Summary? {
        let pairs = paired.compactMap { night -> (watch: Double, fitbit: Double)? in
            guard let watch = night.watch, let fitbit = night.fitbit else { return nil }
            return (measure.minutes(watch), measure.minutes(fitbit))
        }
        guard
            let watchMean = RecoveryStats.mean(pairs.map(\.watch)),
            let fitbitMean = RecoveryStats.mean(pairs.map(\.fitbit)),
            let meanDifference = RecoveryStats.mean(pairs.map { $0.fitbit - $0.watch })
        else { return nil }
        return Summary(
            nights: pairs.count,
            watchMean: watchMean,
            fitbitMean: fitbitMean,
            meanDifference: meanDifference,
            differenceSD: RecoveryStats.standardDeviation(pairs.map { $0.fitbit - $0.watch }),
            spearman: RecoveryStats.spearman(pairs.map(\.watch), pairs.map(\.fitbit))
        )
    }

    /// Builds from the Recovery engine's nights. The Watch side keeps only the
    /// main sleep of each night, so an evening nap before the 6pm boundary's
    /// night doesn't pad it; Fitbit's side is Airlift's import or, failing
    /// that, Google Health's own copy — whichever `NightSamples` carries.
    static func build(_ samples: [NightSamples]) -> SleepComparisonReport {
        let nights = samples.compactMap { night -> SleepNightComparison? in
            let watchSegments = SleepNightMatcher.mainNight(night.appleSleep.filter(\.fromAppleDevice))
            let fitbitSegments = night.airliftedSleep.compactMap { sample -> SleepStageSegment? in
                guard
                    let value = HKCategoryValueSleepAnalysis(rawValue: Int(sample.value)),
                    let stage = StageMapper.stage(for: value)
                else { return nil }
                return SleepStageSegment(stage: stage, start: sample.start, end: sample.end)
            }
            .sorted { $0.start < $1.start }

            let watch = StageMinutes(watchSegments.compactMap { segment in
                SleepAgreement.Stage(segment.value).map { ($0, segment.start, segment.end) }
            })
            let fitbit = StageMinutes(fitbitSegments.map { (SleepAgreement.Stage($0.stage), $0.start, $0.end) })
            guard watch != nil || fitbit != nil else { return nil }

            let device = watchSegments.first { SleepAgreement.Stage($0.value) != nil }
            return SleepNightComparison(
                night: night.night,
                watchSegments: watchSegments,
                fitbitSegments: fitbitSegments,
                watch: watch,
                fitbit: fitbit,
                agreement: watch != nil && fitbit != nil
                    ? SleepAgreement.percent(google: fitbitSegments, apple: watchSegments)
                    : nil,
                watchDevice: device.flatMap { DeviceLabel.apple(hardware: nil, sourceName: $0.sourceName) }
            )
        }
        return SleepComparisonReport(nights: nights.sorted { $0.night < $1.night })
    }
}
