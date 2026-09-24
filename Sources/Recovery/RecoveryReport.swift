import Foundation

/// The four nightly series the screen can compare, and how each is read.
enum RecoverySeries: String, CaseIterable, Identifiable {
    /// Fitbit's RMSSD, airlifted into HealthKit. The reference.
    case fitbitRMSSD
    /// The Watch's own RMSSD, every ~5 minutes (watchOS 27, Ultra 4).
    case appleNativeRMSSD
    /// Apple RMSSD recomputed here from the Watch's beat series.
    case appleRMSSD
    /// Apple's own published SDNN.
    case appleSDNN
    /// Mean heart rate in the selected stages.
    case heartRate
    /// Apple's HRV and heart rate standardised and added together.
    case appleCombined

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fitbitRMSSD: "Fitbit RMSSD"
        case .appleNativeRMSSD: "Apple RMSSD (Watch)"
        case .appleRMSSD: "Apple RMSSD (recomputed)"
        case .appleSDNN: "Apple SDNN (published)"
        case .heartRate: "Apple heart rate"
        case .appleCombined: "Apple combined index"
        }
    }

    var shortName: String {
        switch self {
        case .fitbitRMSSD: "Fitbit"
        case .appleNativeRMSSD: "Watch RMSSD"
        case .appleRMSSD: "Apple RMSSD"
        case .appleSDNN: "Apple SDNN"
        case .heartRate: "Heart rate"
        case .appleCombined: "Combined"
        }
    }

    var unit: String? {
        switch self {
        case .fitbitRMSSD, .appleNativeRMSSD, .appleRMSSD, .appleSDNN: "ms"
        case .heartRate: "bpm"
        case .appleCombined: nil
        }
    }

    /// Whether a bias or limits-of-agreement figure would mean anything against
    /// Fitbit's RMSSD. Only the recomputed RMSSD is the same statistic in the
    /// same unit; comparing milliseconds to bpm, or RMSSD to SDNN, gives a
    /// number that looks like error and is not.
    var isUnitComparableToFitbit: Bool { self == .appleRMSSD || self == .appleNativeRMSSD }

    /// The value used in statistics, oriented so higher always means better
    /// recovered. Heart rate is inverted; everything else already runs that way.
    func statistic(in night: NightRecovery) -> SeriesValue? {
        switch self {
        case .fitbitRMSSD: night.fitbitRMSSD
        case .appleNativeRMSSD: night.appleNativeRMSSD
        case .appleRMSSD: night.appleRMSSD
        case .appleSDNN: night.appleSDNN
        case .heartRate: night.invertedHeartRate
        case .appleCombined: nil // assembled across nights, not from one
        }
    }

    /// The value as it should be displayed — heart rate in bpm, the right way up.
    func display(in night: NightRecovery) -> SeriesValue? {
        switch self {
        case .heartRate: night.stagedHeartRate
        default: statistic(in: night)
        }
    }
}

/// One series measured against Fitbit's RMSSD.
struct RecoveryComparison: Identifiable {
    let series: RecoverySeries
    let summary: RecoveryStats.AgreementSummary
    /// The highest correlation these two could have shown given their own
    /// reliabilities.
    let ceiling: Double?
    /// The observed correlation with measurement noise divided out.
    let disattenuated: Double?
    /// Non-nil when a numeric difference cannot be read as error.
    let caveat: String?

    var id: String { series.rawValue }

    var showsBias: Bool { series.isUnitComparableToFitbit }

    /// True when the observed correlation has essentially reached its ceiling —
    /// the two agree as well as two instruments this noisy could.
    var isAtCeiling: Bool {
        guard let rho = summary.spearman, let ceiling, ceiling > 0 else { return false }
        return rho >= ceiling * 0.95
    }
}

/// How much of a series' nightly movement is signal.
struct SeriesReliability: Identifiable {
    let series: RecoverySeries
    let reliability: Double?
    let nightsWithData: Int
    let medianSamplesPerNight: Double?

    var id: String { series.rawValue }
}

/// Everything the Recovery screen shows for one staging source and one stage
/// selection.
struct RecoveryReport {
    let selection: StageSelection
    let staging: StagingSource
    let nights: [NightRecovery]
    /// One drawable night each, built under the same staging and selection.
    let charts: [NightChart]
    let comparisons: [RecoveryComparison]
    let reliabilities: [SeriesReliability]
    /// The HRV-only, window-by-window comparison the HRV screen draws.
    let hrv: HRVReport
    /// Nightly combined-index values, keyed by night, for charting.
    let combinedIndex: [Date: Double]
    /// What the beat-series probe found — the answer to whether Apple RMSSD
    /// could be recomputed at all.
    let probe: HeartbeatSeriesReader.Probe?

    var pairedNightCount: Int {
        comparisons.first { $0.series == .heartRate }?.summary.n ?? 0
    }

    func comparison(_ series: RecoverySeries) -> RecoveryComparison? {
        comparisons.first { $0.series == series }
    }

    func reliability(_ series: RecoverySeries) -> SeriesReliability? {
        reliabilities.first { $0.series == series }
    }

    static func empty(selection: StageSelection, staging: StagingSource) -> RecoveryReport {
        RecoveryReport(
            selection: selection, staging: staging, nights: [], charts: [], comparisons: [],
            reliabilities: [], hrv: .empty, combinedIndex: [:], probe: nil
        )
    }

    func chart(for night: Date) -> NightChart? {
        charts.first { $0.night == night }
    }

    /// Assembles the report from a set of nights.
    ///
    /// The combined index is built here rather than per night because
    /// standardising needs the whole series. That makes it a retrospective
    /// figure: it uses the full history, including nights after the one being
    /// scored, so it is not what a live daily readiness number could show. It
    /// answers "how well do these agree over this stretch", which is the
    /// question this screen asks.
    static func build(
        nights: [NightRecovery],
        charts: [NightChart] = [],
        hrv: HRVReport = .empty,
        selection: StageSelection,
        staging: StagingSource,
        probe: HeartbeatSeriesReader.Probe?
    ) -> RecoveryReport {
        let ordered = nights.sorted { $0.night < $1.night }
        let combined = combinedIndex(ordered)

        let reliabilities = RecoverySeries.allCases.map { series -> SeriesReliability in
            let values: [SeriesValue] = series == .appleCombined
                ? []
                : ordered.compactMap { series.statistic(in: $0) }
            return SeriesReliability(
                series: series,
                reliability: RecoveryStats.splitHalfReliability(values.compactMap(\.halves)),
                nightsWithData: values.count,
                medianSamplesPerNight: RecoveryStats.median(values.map { Double($0.sampleCount) })
            )
        }

        func reliabilityOf(_ series: RecoverySeries) -> Double? {
            reliabilities.first { $0.series == series }?.reliability
        }
        let fitbitReliability = reliabilityOf(.fitbitRMSSD)

        let targets: [RecoverySeries] = [.appleNativeRMSSD, .appleRMSSD, .appleSDNN, .heartRate, .appleCombined]
        let comparisons = targets.compactMap { series -> RecoveryComparison? in
            let pairs = ordered.compactMap { night -> RecoveryStats.PairedNight? in
                guard let reference = night.fitbitRMSSD?.value else { return nil }
                let target: Double? = series == .appleCombined
                    ? combined[night.night]
                    : series.statistic(in: night)?.value
                guard let target else { return nil }
                return RecoveryStats.PairedNight(
                    night: night.night, reference: reference, target: target
                )
            }
            guard !pairs.isEmpty else { return nil }
            let summary = RecoveryStats.compare(pairs)
            // The combined index has no reliability of its own — it is built
            // from two series whose reliabilities are already reported — so no
            // ceiling is claimed for it rather than a misleading one.
            let ceiling = series == .appleCombined
                ? nil
                : RecoveryStats.attenuationCeiling(fitbitReliability, reliabilityOf(series))
            return RecoveryComparison(
                series: series,
                summary: summary,
                ceiling: ceiling,
                disattenuated: RecoveryStats.disattenuated(
                    summary.spearman, fitbitReliability, reliabilityOf(series)
                ),
                caveat: caveat(for: series)
            )
        }

        return RecoveryReport(
            selection: selection,
            staging: staging,
            nights: ordered,
            charts: charts.sorted { $0.night < $1.night },
            comparisons: comparisons,
            reliabilities: reliabilities,
            hrv: hrv,
            combinedIndex: combined,
            probe: probe
        )
    }

    private static func caveat(for series: RecoverySeries) -> String? {
        switch series {
        case .appleSDNN:
            "Apple publishes SDNN, Fitbit reports RMSSD — different statistics, so a difference between them is expected and is not error."
        case .heartRate:
            "Milliseconds against bpm: only the ranking and the night-to-night changes are comparable, never the values."
        case .appleCombined:
            "Standardised against this whole stretch of nights, later nights included — a retrospective figure, not what a live daily score could show."
        case .appleNativeRMSSD:
            "Only nights the Watch wrote its own RMSSD — watchOS 27 on Ultra 4 hardware."
        case .appleRMSSD, .fitbitRMSSD:
            nil
        }
    }

    /// HRV and heart rate, each standardised across the nights and added.
    ///
    /// Exponentiating the sum keeps the index positive so the log-domain
    /// statistics apply unchanged: `log(combined)` is exactly the sum of the two
    /// z-scores, so a night-to-night change in the index is a change in the
    /// z-sum and nothing is distorted by the round trip.
    ///
    /// Apple's recomputed RMSSD is preferred; where the Watch published no beat
    /// series the night falls back to its published SDNN, since either one
    /// standardises to the same scale.
    private static func combinedIndex(_ nights: [NightRecovery]) -> [Date: Double] {
        let hrvByNight = nights.reduce(into: [Date: Double]()) { result, night in
            if let value = night.appleRMSSD?.value ?? night.appleSDNN?.value {
                result[night.night] = log(value)
            }
        }
        let hrByNight = nights.reduce(into: [Date: Double]()) { result, night in
            if let value = night.invertedHeartRate?.value {
                result[night.night] = log(value)
            }
        }
        let shared = nights.map(\.night).filter { hrvByNight[$0] != nil && hrByNight[$0] != nil }
        guard shared.count >= 3 else { return [:] }

        guard
            let hrvMean = RecoveryStats.mean(shared.compactMap { hrvByNight[$0] }),
            let hrvSD = RecoveryStats.standardDeviation(shared.compactMap { hrvByNight[$0] }),
            let hrMean = RecoveryStats.mean(shared.compactMap { hrByNight[$0] }),
            let hrSD = RecoveryStats.standardDeviation(shared.compactMap { hrByNight[$0] }),
            hrvSD > 0, hrSD > 0
        else { return [:] }

        return shared.reduce(into: [Date: Double]()) { result, night in
            guard let hrv = hrvByNight[night], let hr = hrByNight[night] else { return }
            result[night] = exp((hrv - hrvMean) / hrvSD + (hr - hrMean) / hrSD)
        }
    }
}
