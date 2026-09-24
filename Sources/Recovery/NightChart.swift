import Foundation

/// One night drawn: the hypnogram behind, the two HRV series and the heart-rate
/// trace over it, with every mark carrying whether the current stage selection
/// kept it.
///
/// `inZone` is the point of the picture. The restriction is easy to state and
/// hard to believe until you see how little of a night survives it — on the
/// Watch, four HRV readings become one or two.
struct NightChart: Identifiable, Equatable {
    var id: Date { night }

    let night: Date
    let domain: ClosedRange<Date>
    let bands: [StageBand]
    /// Fitbit's RMSSD, airlifted.
    let fitbit: [ChartPoint]
    /// Apple's HRV — the Watch's own RMSSD where it wrote one, recomputed
    /// RMSSD where beat series exist, its published SDNN otherwise.
    let apple: [ChartPoint]
    let appleKind: AppleHRVKind
    /// Apple's heart rate, in bpm.
    let heartRate: [ChartPoint]

    var isEmpty: Bool { fitbit.isEmpty && apple.isEmpty && heartRate.isEmpty && bands.isEmpty }

    var appleIsRecomputed: Bool { appleKind == .recomputed }

    enum AppleHRVKind: Equatable {
        case native, recomputed, published

        var label: String {
            switch self {
            case .native: "Watch RMSSD"
            case .recomputed: "Apple RMSSD"
            case .published: "Apple SDNN"
            }
        }
    }

    /// Marks the selection kept, over marks it saw — the sampling density the
    /// restriction actually leaves behind.
    func kept(_ points: [ChartPoint]) -> (kept: Int, total: Int) {
        (points.filter(\.inZone).count, points.count)
    }

    struct StageBand: Identifiable, Equatable {
        let id: Int
        let stage: SleepAgreement.Stage
        let start: Date
        let end: Date
        /// True when this run is inside the current stage selection.
        let inZone: Bool
    }

    struct ChartPoint: Identifiable, Equatable {
        let id: Int
        let date: Date
        let value: Double
        /// False for samples the selection excluded — drawn faded rather than
        /// dropped, so what was discarded stays visible.
        let inZone: Bool
    }
}

extension NightSamples {

    /// Builds the picture for one night under the same staging and selection
    /// the statistics used, so the chart and the numbers can never disagree.
    func chart(selection: StageSelection, staging: StagingSource) -> NightChart {
        let index = stageIndex(staging)
        let runs = index.runs()

        let bands = runs.enumerated().map { offset, run in
            NightChart.StageBand(
                id: offset,
                stage: run.stage,
                start: run.interval.start,
                end: run.interval.end,
                inZone: selection.includes(run.stage)
            )
        }

        func points<Sample>(
            _ samples: [Sample],
            date: (Sample) -> Date,
            value: (Sample) -> Double
        ) -> [NightChart.ChartPoint] {
            samples.enumerated().compactMap { offset, sample in
                let reading = value(sample)
                guard reading.isFinite, reading > 0 else { return nil }
                return NightChart.ChartPoint(
                    id: offset,
                    date: date(sample),
                    value: reading,
                    inZone: index.includes(date(sample), in: selection)
                )
            }
        }

        // RMSSD is what makes the two devices comparable. The Watch's own
        // wins where it wrote one — same statistic, same cadence as Fitbit —
        // then RMSSD recomputed from beats; the published SDNN stands in only
        // where neither exists, and the kind says which is on screen.
        let recomputed = tachograms.compactMap { tachogram -> (Date, Double)? in
            guard let rmssd = HRVMetrics.compute(tachogram).rmssd else { return nil }
            return (tachogram.start, rmssd)
        }
        let appleKind: NightChart.AppleHRVKind = !appleNativeRMSSD.isEmpty
            ? .native
            : recomputed.isEmpty ? .published : .recomputed
        let apple = switch appleKind {
        case .native: points(appleNativeRMSSD, date: \.start, value: \.value)
        case .recomputed: points(recomputed, date: { $0.0 }, value: { $0.1 })
        case .published: points(appleHRV, date: \.start, value: \.value)
        }

        return NightChart(
            night: night,
            domain: Self.domain(
                runs: runs,
                fallback: appleHeartRate.map(\.date) + airliftedHRV.map(\.start),
                window: window
            ),
            bands: bands,
            fitbit: points(airliftedHRV, date: \.start, value: \.value),
            apple: apple,
            appleKind: appleKind,
            heartRate: points(appleHeartRate, date: \.date, value: \.bpm)
        )
    }

    /// The x-axis: the scored night where there is one, the samples otherwise,
    /// and the whole 6pm→6pm window only as a last resort — a night shown
    /// against 24 hours of empty axis is unreadable.
    private static func domain(
        runs: [(stage: SleepAgreement.Stage, interval: DateInterval)],
        fallback: [Date],
        window: DateInterval
    ) -> ClosedRange<Date> {
        let starts = runs.map { $0.interval.start } + fallback
        let ends = runs.map { $0.interval.end } + fallback
        guard let first = starts.min(), let last = ends.max(), last > first else {
            return window.start...window.end
        }
        let pad = max(600, last.timeIntervalSince(first) * 0.03)
        return first.addingTimeInterval(-pad)...last.addingTimeInterval(pad)
    }
}
