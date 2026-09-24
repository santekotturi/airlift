import Foundation

/// The HRV numbers that can be put on one axis.
///
/// All are milliseconds, which is what makes a direct overlay honest — but they
/// are not all the same statistic. Apple's spot checks publish SDNN; Fitbit
/// reports RMSSD; the derived series is RMSSD recomputed here from Apple's own
/// beats, so older watches have something comparable with Fitbit like for like.
/// Ultra 4-class watches on watchOS 27 publish RMSSD themselves, every ~5
/// minutes, which makes the recomputation a cross-check rather than the only
/// route.
enum HRVSource: String, CaseIterable, Identifiable {
    /// The Watch's own RMSSD, every ~5 minutes (watchOS 27, Ultra 4).
    case appleNative
    /// Apple Watch's own published SDNN.
    case applePublished
    /// RMSSD recomputed here from Apple's beat-to-beat series.
    case appleDerived
    /// Fitbit's RMSSD, airlifted into Health.
    case fitbit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleNative: "Watch RMSSD"
        case .applePublished: "Apple SDNN"
        case .appleDerived: "Recomputed RMSSD"
        case .fitbit: "Fitbit RMSSD"
        }
    }

    var detail: String {
        switch self {
        case .appleNative: "The Watch's own RMSSD, every ~5 minutes. New with watchOS 27 on Ultra 4."
        case .applePublished: "What the Watch publishes. SDNN over ~60 s, barely artifact-filtered."
        case .appleDerived: "Recomputed here from the Watch's own beats — RMSSD, 20% artifact filter."
        case .fitbit: "The reference. RMSSD roughly every 5 minutes."
        }
    }

    var statistic: String {
        self == .applePublished ? "SDNN" : "RMSSD"
    }

    /// True for the series that can be compared with Fitbit as a value, not
    /// merely as a ranking.
    var isComparableToFitbit: Bool { self == .appleDerived || self == .appleNative }
}

/// One Apple HRV reading, with whatever Fitbit was saying at the same moment.
///
/// This is the unit the "regions" view is built from. A nightly average hides
/// the thing worth seeing — that the two devices can agree at 2am and disagree
/// at 5am — because averaging is exactly the operation that removes it.
///
/// On a watch that writes RMSSD itself, the window is one of its ~5-minute
/// readings, and a spot check that fell inside it rides along. Otherwise it is
/// one spot check.
struct HRVWindow: Identifiable, Equatable {
    /// Unique across the whole report once `HRVReport.build` has run.
    var id: Int
    let night: Date
    /// When the Watch opened the sensor.
    let at: Date
    /// The stage this window fell in, under whichever hypnogram was selected.
    let stage: SleepAgreement.Stage?

    let applePublished: Double?
    let appleDerived: Double?
    /// Mean of the Fitbit readings inside the match tolerance.
    let fitbit: Double?
    let fitbitSampleCount: Int

    /// Share of this tachogram's intervals the filter rejected. High values are
    /// the reason to distrust a window even when it produced a clean-looking
    /// number.
    let rejectionRate: Double?
    /// Beat pairs the derived RMSSD was actually built on.
    let successivePairs: Int
    /// The Watch's own RMSSD for this window.
    var appleNative: Double? = nil

    var nativeErrorPct: Double? {
        guard let appleNative, let fitbit, fitbit > 0 else { return nil }
        return (appleNative / fitbit - 1) * 100
    }

    /// Signed difference between the derived RMSSD and Fitbit's, as a
    /// percentage of Fitbit's — the local version of the nightly bias.
    var derivedErrorPct: Double? {
        guard let appleDerived, let fitbit, fitbit > 0 else { return nil }
        return (appleDerived / fitbit - 1) * 100
    }

    var publishedErrorPct: Double? {
        guard let applePublished, let fitbit, fitbit > 0 else { return nil }
        return (applePublished / fitbit - 1) * 100
    }

    func value(_ source: HRVSource) -> Double? {
        switch source {
        case .appleNative: appleNative
        case .applePublished: applePublished
        case .appleDerived: appleDerived
        case .fitbit: fitbit
        }
    }

    /// Usable when Fitbit and at least one Apple series have something to say —
    /// a window where Fitbit was not sampling proves nothing about agreement.
    /// Each statistic then pairs only the series it is about, so a native-only
    /// window never counts toward the spot-check comparison.
    var isComplete: Bool {
        fitbit != nil && (appleNative != nil || applePublished != nil || appleDerived != nil)
    }
}

/// How the three series compare inside one stage.
struct HRVZone: Identifiable {
    let stage: SleepAgreement.Stage
    let windowCount: Int
    let medians: [HRVSource: Double]
    /// Rank agreement with Fitbit, window by window, inside this stage.
    let derivedSpearman: Double?
    let publishedSpearman: Double?
    /// Typical signed error against Fitbit, as a percentage.
    let derivedBiasPct: Double?
    let publishedBiasPct: Double?
    let medianRejectionRate: Double?
    var nativeSpearman: Double? = nil
    var nativeBiasPct: Double? = nil

    var id: String { String(describing: stage) }

    var displayName: String {
        switch stage {
        case .awake: "Awake"
        case .core: "Core"
        case .deep: "Deep"
        case .rem: "REM"
        case .asleep: "Asleep (unstaged)"
        }
    }

    /// Whether recomputing beat the published number in this zone — the whole
    /// question, answered per stage rather than once for the night.
    var derivationWins: Bool {
        guard let derivedSpearman, let publishedSpearman else { return false }
        return derivedSpearman > publishedSpearman
    }
}

/// Everything the HRV screen shows.
struct HRVReport {
    let windows: [HRVWindow]
    let zones: [HRVZone]
    /// Window-level agreement with Fitbit, across every stage at once.
    let derivedOverall: RecoveryStats.AgreementSummary
    let publishedOverall: RecoveryStats.AgreementSummary
    /// How much denser Fitbit's sampling is over the same nights.
    let fitbitSamplesPerNight: Double?
    let appleWindowsPerNight: Double?
    var nativeOverall: RecoveryStats.AgreementSummary = .insufficient
    /// The Watch's own RMSSD readings per night, over the nights it wrote any.
    var nativeReadingsPerNight: Double? = nil

    var hasNative: Bool { windows.contains { $0.appleNative != nil } }

    var nightCount: Int { Set(windows.map(\.night)).count }
    var completeWindowCount: Int { windows.filter(\.isComplete).count }

    static let empty = HRVReport(
        windows: [], zones: [],
        derivedOverall: .insufficient, publishedOverall: .insufficient,
        fitbitSamplesPerNight: nil, appleWindowsPerNight: nil
    )

    func zone(_ stage: SleepAgreement.Stage) -> HRVZone? {
        zones.first { $0.stage == stage }
    }

    func windows(for night: Date) -> [HRVWindow] {
        windows.filter { $0.night == night }.sorted { $0.at < $1.at }
    }

    /// Builds the report from every night's matched windows.
    static func build(windows: [HRVWindow], fitbitSamplesPerNight: Double?) -> HRVReport {
        var ordered = windows.sorted { $0.at < $1.at }
        // Windows are numbered per night as they are built; charts that draw
        // several nights at once need them unique.
        for index in ordered.indices { ordered[index].id = index }
        let complete = ordered.filter(\.isComplete)
        let nights = Set(ordered.map(\.night)).count
        let nativePerNight = Dictionary(grouping: ordered.filter { $0.appleNative != nil }, by: \.night)
            .values.map { Double($0.count) }

        func summary(_ source: HRVSource) -> RecoveryStats.AgreementSummary {
            // Each window is one observation, so "night" here is the window's
            // instant — consecutive-night change agreement is meaningless at
            // this resolution and comes out empty, which is correct.
            RecoveryStats.compare(
                complete.compactMap { window in
                    guard let target = window.value(source), let reference = window.fitbit else { return nil }
                    return RecoveryStats.PairedNight(
                        night: window.at, reference: reference, target: target
                    )
                }
            )
        }

        return HRVReport(
            windows: ordered,
            zones: zones(from: complete),
            derivedOverall: summary(.appleDerived),
            publishedOverall: summary(.applePublished),
            fitbitSamplesPerNight: fitbitSamplesPerNight,
            appleWindowsPerNight: nights > 0 ? Double(ordered.count) / Double(nights) : nil,
            nativeOverall: summary(.appleNative),
            nativeReadingsPerNight: RecoveryStats.median(nativePerNight)
        )
    }

    private static func zones(from windows: [HRVWindow]) -> [HRVZone] {
        let order: [SleepAgreement.Stage] = [.deep, .core, .rem, .asleep, .awake]
        return order.compactMap { stage -> HRVZone? in
            let inStage = windows.filter { $0.stage == stage }
            // Below a handful of windows a stage-level correlation is noise
            // wearing a number's clothes.
            guard inStage.count >= 5 else { return nil }

            // Paired window by window: a window missing one series must drop
            // out of that series' correlation, not shift every later pair.
            func rank(_ source: HRVSource) -> Double? {
                let pairs = inStage.compactMap { window -> (Double, Double)? in
                    guard let fitbit = window.fitbit, let value = window.value(source) else { return nil }
                    return (fitbit, value)
                }
                return RecoveryStats.spearman(pairs.map(\.0), pairs.map(\.1))
            }
            var medians: [HRVSource: Double] = [:]
            for source in HRVSource.allCases {
                if let median = RecoveryStats.median(inStage.compactMap { $0.value(source) }) {
                    medians[source] = median
                }
            }
            return HRVZone(
                stage: stage,
                windowCount: inStage.count,
                medians: medians,
                derivedSpearman: rank(.appleDerived),
                publishedSpearman: rank(.applePublished),
                derivedBiasPct: RecoveryStats.median(inStage.compactMap(\.derivedErrorPct)),
                publishedBiasPct: RecoveryStats.median(inStage.compactMap(\.publishedErrorPct)),
                medianRejectionRate: RecoveryStats.median(inStage.compactMap(\.rejectionRate)),
                nativeSpearman: rank(.appleNative),
                nativeBiasPct: RecoveryStats.median(inStage.compactMap(\.nativeErrorPct))
            )
        }
    }
}

extension NightSamples {

    /// How far either side of an Apple reading a Fitbit reading still counts as
    /// "the same moment".
    ///
    /// Fitbit samples about every five minutes, so ±5 minutes reliably finds a
    /// neighbour without reaching so far that it averages across a stage
    /// boundary. Widening this trades a truer match for a bigger sample.
    static let hrvMatchTolerance: TimeInterval = 5 * 60

    /// Pairs each Apple HRV reading with what Fitbit was reporting alongside it.
    ///
    /// On an older watch the spot checks are the scarce side — four or five a
    /// night against Fitbit's ninety — so each one anchors a window and looks
    /// for Fitbit within `tolerance`.
    ///
    /// Where the Watch wrote its own RMSSD, those ~5-minute readings anchor
    /// instead: the two devices then sample at the same cadence, and each Watch
    /// window is paired with the Fitbit readings that fall inside it, which on
    /// Fitbit's 5-minute grid is almost always exactly one. A spot check inside
    /// the window is attached to it; one outside every window still gets its
    /// own, so no reading is lost by the switch.
    func hrvWindows(
        staging: StagingSource,
        tolerance: TimeInterval = NightSamples.hrvMatchTolerance
    ) -> [HRVWindow] {
        let index = stageIndex(staging)
        let publishedByTime = appleHRV.sorted { $0.start < $1.start }
        let fitbitReadings = airliftedHRV.filter { $0.value.isFinite && $0.value > 0 }

        func fitbitMean(_ readings: [HealthKitReader.OwnSample]) -> Double? {
            readings.isEmpty ? nil : readings.reduce(0) { $0 + $1.value } / Double(readings.count)
        }

        // Apple's own number for a spot check: the published sample closest in
        // time, within the tolerance.
        func published(near instant: Date) -> QuantitySample? {
            publishedByTime
                .filter { abs($0.start.timeIntervalSince(instant)) <= tolerance }
                .min { abs($0.start.timeIntervalSince(instant)) < abs($1.start.timeIntervalSince(instant)) }
        }

        let native = appleNativeRMSSD
            .filter { $0.value.isFinite && $0.value > 0 }
            .sorted { $0.start < $1.start }
        var claimed = Set<UUID>()

        let nativeWindows = native.map { reading -> HRVWindow in
            let span = DateInterval(start: reading.start, end: max(reading.end, reading.start))
            let midpoint = span.start.addingTimeInterval(span.duration / 2)
            let spot = tachograms.first { !claimed.contains($0.id) && span.contains($0.start) }
            if let spot { claimed.insert(spot.id) }
            let metrics = spot.map { HRVMetrics.compute($0) }
            let inside = fitbitReadings.filter { span.contains($0.start) }
            return HRVWindow(
                id: 0,
                night: night,
                at: midpoint,
                stage: index.stage(at: midpoint),
                applePublished: spot.flatMap { published(near: $0.start) }?.value,
                appleDerived: metrics?.rmssd,
                fitbit: fitbitMean(inside),
                fitbitSampleCount: inside.count,
                rejectionRate: metrics?.rejectionRate,
                successivePairs: metrics?.successivePairs ?? 0,
                appleNative: reading.value
            )
        }

        let spotWindows = tachograms.filter { !claimed.contains($0.id) }.map { tachogram -> HRVWindow in
            let metrics = HRVMetrics.compute(tachogram)
            let nearby = fitbitReadings.filter {
                abs($0.start.timeIntervalSince(tachogram.start)) <= tolerance
            }
            return HRVWindow(
                id: 0,
                night: night,
                at: tachogram.start,
                stage: index.stage(at: tachogram.start),
                applePublished: published(near: tachogram.start)?.value,
                appleDerived: metrics.rmssd,
                fitbit: fitbitMean(nearby),
                fitbitSampleCount: nearby.count,
                rejectionRate: metrics.rejectionRate,
                successivePairs: metrics.successivePairs
            )
        }

        return (nativeWindows + spotWindows)
            .sorted { $0.at < $1.at }
            .enumerated()
            .map { offset, window in
                var window = window
                window.id = offset
                return window
            }
    }

    /// Fitbit readings that landed inside scored sleep — the density the Apple
    /// side is being compared against.
    func fitbitHRVSampleCount(staging: StagingSource) -> Int {
        let index = stageIndex(staging)
        return airliftedHRV.filter { index.stage(at: $0.start)?.isAsleep == true }.count
    }
}
