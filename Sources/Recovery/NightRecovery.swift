import Foundation

/// One night's raw material, straight out of HealthKit and not yet staged.
///
/// Both HRV streams live in the same HealthKit type — `heartRateVariabilitySDNN`
/// — separated only by who wrote them: Apple's readings are the Watch's own, the
/// airlifted ones are Fitbit's RMSSD that Airlift imported. Keeping them apart
/// here is what makes the whole comparison possible, and mixing them would
/// quietly correlate a series with itself.
struct NightSamples {
    /// Midnight of the day the night wakes into, matching how sleep and every
    /// overnight metric are already labelled.
    let night: Date
    /// The 6pm→6pm window the night is read from.
    let window: DateInterval

    let appleSleep: [AppleSleepSegment]
    let airliftedSleep: [HealthKitReader.OwnSample]
    let appleHeartRate: [HRSample]
    /// Apple Watch's own published SDNN — the ~60 s spot checks only. The
    /// continuous 5-minute SDNN newer watches also write is left out, so this
    /// series means the same thing on every watch.
    let appleHRV: [QuantitySample]
    /// Fitbit's RMSSD, as imported by Airlift.
    let airliftedHRV: [HealthKitReader.OwnSample]
    /// Beat-to-beat series, when the Watch publishes them.
    let tachograms: [Tachogram]
    /// The Watch's own RMSSD, every ~5 minutes. Only Ultra 4-class hardware on
    /// watchOS 27 writes it; empty for every night before that.
    var appleNativeRMSSD: [QuantitySample] = []

    func stageIndex(_ source: StagingSource) -> StageIndex {
        switch source {
        case .apple: StageIndex(apple: appleSleep)
        case .fitbit: StageIndex(airlifted: airliftedSleep)
        case .bothAgree: StageIndex.intersection(
            StageIndex(apple: appleSleep), StageIndex(airlifted: airliftedSleep)
        )
        }
    }
}

/// One nightly number, with the evidence behind it.
///
/// `sampleCount` travels with the value because it is the finding: a nightly
/// mean over 68 heart-rate samples and one over 4 HRV readings are not the same
/// kind of number, and the difference between them turned out to explain more
/// than the choice of metric did.
struct SeriesValue: Equatable {
    let value: Double
    let sampleCount: Int
    /// The same statistic computed from alternating samples — odd indices and
    /// even. Correlating the two halves across nights is how much of the value
    /// is signal rather than noise.
    let halfA: Double?
    let halfB: Double?

    var halves: (a: Double, b: Double)? {
        guard let halfA, let halfB else { return nil }
        return (halfA, halfB)
    }
}

/// One night, reduced to the handful of numbers the comparison runs on.
struct NightRecovery: Identifiable, Equatable {
    var id: Date { night }

    let night: Date
    let window: DateInterval
    let selection: StageSelection
    let staging: StagingSource

    /// Fitbit RMSSD, milliseconds — the reference.
    let fitbitRMSSD: SeriesValue?
    /// Apple RMSSD recomputed from beat series, milliseconds. The like-for-like
    /// counterpart to Fitbit's number, and `nil` whenever the Watch published no
    /// beats to recompute from.
    let appleRMSSD: SeriesValue?
    /// Apple's own published SDNN, milliseconds — a different statistic, kept
    /// so the recomputation can be checked against what Apple says.
    let appleSDNN: SeriesValue?
    /// The Watch's own RMSSD, milliseconds — the same statistic at the same
    /// cadence as Fitbit's, on nights the Watch wrote it.
    var appleNativeRMSSD: SeriesValue? = nil
    /// Mean heart rate inside the selected stages, bpm. Lower is better
    /// recovered, so it runs opposite to the HRV series.
    let stagedHeartRate: SeriesValue?

    /// Minutes of the night the selection covered — the denominator that makes
    /// "4 samples in the zone" interpretable.
    let stagedMinutes: Int
    /// True when the chosen source scored this night at all.
    let hasStaging: Bool

    /// Heart rate flipped to run the same direction as HRV, so it can be
    /// compared without the correlation coming out backwards. Order-equivalent
    /// to negating the log, in a form the log-domain statistics accept.
    var invertedHeartRate: SeriesValue? {
        stagedHeartRate.map {
            SeriesValue(
                value: 1000 / $0.value,
                sampleCount: $0.sampleCount,
                halfA: $0.halfA.map { half in 1000 / half },
                halfB: $0.halfB.map { half in 1000 / half }
            )
        }
    }
}

extension NightSamples {

    /// Minutes of settling-in dropped from the start of sleep.
    ///
    /// Heart rate falls steeply through sleep onset and HRV climbs, so the
    /// first half hour is dominated by that transient rather than by how
    /// recovered the night was. Trimming it is standard in overnight HRV work
    /// and it measurably steadies the nightly value.
    static let onsetTrimMinutes: Double = 30

    /// Reduces the night under one staging source and one stage selection.
    ///
    /// Every series is filtered by the *same* index, so when the comparison
    /// says HRV and heart rate disagree, they at least disagree about the same
    /// minutes.
    func recovery(
        selection: StageSelection,
        staging: StagingSource,
        onsetTrimMinutes: Double = NightSamples.onsetTrimMinutes
    ) -> NightRecovery {
        let index = stageIndex(staging)
        let earliest = index.runs()
            .first { $0.stage.isAsleep }?
            .interval.start
            .addingTimeInterval(onsetTrimMinutes * 60)

        func isEligible(_ instant: Date) -> Bool {
            if let earliest, instant < earliest { return false }
            return index.includes(instant, in: selection)
        }

        let heartRate = Self.value(
            from: appleHeartRate.filter { isEligible($0.date) },
            value: \.bpm
        )
        let fitbit = Self.value(
            from: airliftedHRV.filter { isEligible($0.start) },
            value: \.value
        )
        let sdnn = Self.value(
            from: appleHRV.filter { isEligible($0.start) },
            value: \.value
        )
        let recomputed = Self.pooledRMSSD(tachograms.filter { isEligible($0.start) })
        let native = Self.value(
            from: appleNativeRMSSD.filter { isEligible($0.start) },
            value: \.value
        )

        return NightRecovery(
            night: night,
            window: window,
            selection: selection,
            staging: staging,
            fitbitRMSSD: fitbit,
            appleRMSSD: recomputed,
            appleSDNN: sdnn,
            appleNativeRMSSD: native,
            stagedHeartRate: heartRate,
            stagedMinutes: index.minuteCount(in: selection),
            hasStaging: !index.isEmpty
        )
    }

    /// Mean of the eligible samples, plus the same mean over alternating
    /// samples. Interleaved rather than split down the middle so a within-night
    /// trend — HRV rises through the night — does not read as measurement
    /// noise when the halves are compared.
    private static func value<Sample>(
        from samples: [Sample],
        value: (Sample) -> Double
    ) -> SeriesValue? {
        let values = samples.map(value).filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return nil }
        let odd = values.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let even = values.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
        return SeriesValue(
            value: values.reduce(0, +) / Double(values.count),
            sampleCount: values.count,
            // A half needs at least two samples to be a mean of anything; with
            // three readings a night there is often no honest split to make.
            halfA: odd.count >= 2 ? odd.reduce(0, +) / Double(odd.count) : nil,
            halfB: even.count >= 2 ? even.reduce(0, +) / Double(even.count) : nil
        )
    }

    /// The night's RMSSD, pooled across readings on the squares and weighted by
    /// how many beat pairs each contributed.
    private static func pooledRMSSD(_ tachograms: [Tachogram]) -> SeriesValue? {
        guard !tachograms.isEmpty else { return nil }
        let metrics = tachograms.map { HRVMetrics.compute($0) }
        guard let pooled = HRVMetrics.pooled(metrics).rmssd else { return nil }
        let odd = metrics.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let even = metrics.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
        return SeriesValue(
            value: pooled,
            sampleCount: metrics.count,
            halfA: odd.count >= 2 ? HRVMetrics.pooled(odd).rmssd : nil,
            halfB: even.count >= 2 ? HRVMetrics.pooled(even).rmssd : nil
        )
    }
}
