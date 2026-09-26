import Foundation

/// One beat the Watch timed, relative to the start of its series.
struct Heartbeat: Equatable {
    let timeSinceSeriesStart: TimeInterval
    /// The Watch's own flag: it could not see the beat immediately before this
    /// one, so the interval ending here spans an unknown number of beats.
    let precededByGap: Bool
}

/// One Apple Watch beat-to-beat series — the ~60 s tachogram the Watch records
/// alongside each HRV reading.
///
/// This is the only place Apple exposes the raw material HRV is computed from.
/// The averaged `heartRate` samples cannot substitute: they are mean BPM over a
/// window, so the beat timing HRV is *made of* has already been discarded.
struct Tachogram: Equatable, Identifiable {
    let id: UUID
    let start: Date
    let beats: [Heartbeat]

    init(id: UUID = UUID(), start: Date, beats: [Heartbeat]) {
        self.id = id
        self.start = start
        self.beats = beats
    }

    var end: Date {
        start.addingTimeInterval(beats.last?.timeSinceSeriesStart ?? 0)
    }

    /// Successive inter-beat intervals in seconds. `nil` marks a break in the
    /// chain — a gap the Watch flagged — where neither an interval nor a
    /// successive difference across it is measurable.
    var rrIntervals: [Double?] {
        guard beats.count > 1 else { return [] }
        return zip(beats, beats.dropFirst()).map { previous, beat in
            beat.precededByGap
                ? nil
                : beat.timeSinceSeriesStart - previous.timeSinceSeriesStart
        }
    }
}

/// Rejects intervals that are physiologically implausible or discontinuous.
///
/// The Malik criterion: an interval more than `tolerance` away from the last
/// *accepted* one is an artifact — a missed or doubled beat — not a real
/// change in the heart's rhythm. Comparing to the last accepted interval
/// rather than the raw predecessor stops one bad beat from dragging the
/// reference along with it and rejecting the good beats that follow.
///
/// Apple applies its own (undocumented) cleaning before publishing SDNN. Doing
/// it here is the point: the filter becomes visible, tunable, and identical
/// across both devices' data.
struct ArtifactFilter: Equatable {
    /// Fractional deviation from the last accepted interval that still counts
    /// as a real beat. 20% is Malik et al. 1989.
    var tolerance: Double = 0.20
    /// Plausible interval range in seconds — 0.27 s to 2.4 s is 25–222 bpm.
    ///
    /// Deliberately wider than the 0.3–2.0 s often quoted, and deliberately the
    /// same bounds as the reference implementation these numbers were validated
    /// against (`recoverylab`'s `HRVConfig`). The range filter is there to catch
    /// the physically impossible; Malik does the discriminating, and a tight
    /// range would quietly do Malik's job with no reference interval to judge
    /// against. Changing either value invalidates `TachogramFixtureTests`.
    var plausible: ClosedRange<Double> = 0.27...2.40

    static let malik = ArtifactFilter()

    func isPlausible(_ rr: Double) -> Bool { plausible.contains(rr) }

    func isContinuous(_ rr: Double, after lastAccepted: Double) -> Bool {
        abs(rr - lastAccepted) <= tolerance * lastAccepted
    }
}

/// Time-domain HRV computed from one tachogram (or pooled across several).
///
/// RMSSD, not SDNN, is the headline: it is what Fitbit reports, so computing it
/// here is what makes the two devices comparable at all. SDNN comes along for
/// free and lets the recomputation be checked against Apple's own published
/// number for the same beats.
struct HRVMetrics: Equatable {
    /// Root mean square of successive differences, milliseconds.
    let rmssd: Double?
    /// Standard deviation of accepted intervals, milliseconds.
    let sdnn: Double?
    /// Mean accepted interval, milliseconds.
    let meanRR: Double?
    let acceptedIntervals: Int
    let rejectedIntervals: Int
    /// Adjacent accepted pairs — the denominator RMSSD is actually built on.
    let successivePairs: Int

    static let empty = HRVMetrics(
        rmssd: nil, sdnn: nil, meanRR: nil,
        acceptedIntervals: 0, rejectedIntervals: 0, successivePairs: 0
    )

    /// Mean heart rate implied by the accepted beats, bpm — a cross-check that
    /// the beat series and the averaged `heartRate` samples describe the same
    /// minute.
    var impliedBPM: Double? { meanRR.map { 60_000 / $0 } }

    /// Share of intervals the filter threw out. High values mean the reading
    /// was mostly artifact and the HRV number it produced should not be
    /// trusted, however clean it looks.
    var rejectionRate: Double? {
        let total = acceptedIntervals + rejectedIntervals
        return total > 0 ? Double(rejectedIntervals) / Double(total) : nil
    }

    static func compute(_ tachogram: Tachogram, filter: ArtifactFilter = .malik) -> HRVMetrics {
        compute(rrIntervals: tachogram.rrIntervals, filter: filter)
    }

    /// The core pass. `nil` entries break the chain, so a gap costs the
    /// successive difference across it but not the intervals on either side.
    static func compute(rrIntervals: [Double?], filter: ArtifactFilter = .malik) -> HRVMetrics {
        var accepted: [Double] = []
        var squaredDiffs: [Double] = []
        var rejected = 0
        var lastAccepted: Double?
        // True when the previous interval was accepted *and* adjacent to this
        // one — the condition for their difference to be a real successive
        // difference rather than a jump across removed beats.
        var previousWasAdjacent = false

        for entry in rrIntervals {
            guard let rr = entry else {
                // Flagged gap: the chain breaks, but the reference interval
                // survives — the rhythm after a gap is still the same heart.
                previousWasAdjacent = false
                continue
            }
            let plausible = filter.isPlausible(rr)
            let continuous = lastAccepted.map { filter.isContinuous(rr, after: $0) } ?? true
            guard plausible && continuous else {
                rejected += 1
                previousWasAdjacent = false
                continue
            }
            if previousWasAdjacent, let previous = lastAccepted {
                squaredDiffs.append((rr - previous) * (rr - previous))
            }
            accepted.append(rr)
            lastAccepted = rr
            previousWasAdjacent = true
        }

        // Seconds in, milliseconds out — the unit HealthKit and Fitbit both use.
        let rmssd = squaredDiffs.isEmpty
            ? nil
            : (squaredDiffs.reduce(0, +) / Double(squaredDiffs.count)).squareRoot() * 1000
        let sdnn = accepted.count > 1 ? standardDeviation(accepted) * 1000 : nil
        let meanRR = accepted.isEmpty
            ? nil
            : accepted.reduce(0, +) / Double(accepted.count) * 1000

        return HRVMetrics(
            rmssd: rmssd,
            sdnn: sdnn,
            meanRR: meanRR,
            acceptedIntervals: accepted.count,
            rejectedIntervals: rejected,
            successivePairs: squaredDiffs.count
        )
    }

    /// Combines a night's readings into one number.
    ///
    /// Pooling is on the *squares*, weighted by how many successive pairs each
    /// reading contributed — RMSSD is a root-mean-square, so averaging the
    /// roots would quietly under-weight the noisier, longer readings that
    /// carry the most information:
    ///
    ///     RMSSD_pooled = sqrt( Σ nᵢ · RMSSDᵢ² / Σ nᵢ )
    static func pooled(_ metrics: [HRVMetrics]) -> HRVMetrics {
        var weightedSquares = 0.0
        var pairs = 0
        var accepted = 0
        var rejected = 0
        var rrSum = 0.0
        var rrCount = 0
        var sdnnWeighted = 0.0
        var sdnnCount = 0

        for metric in metrics {
            if let rmssd = metric.rmssd, metric.successivePairs > 0 {
                weightedSquares += Double(metric.successivePairs) * rmssd * rmssd
                pairs += metric.successivePairs
            }
            if let sdnn = metric.sdnn, metric.acceptedIntervals > 1 {
                sdnnWeighted += Double(metric.acceptedIntervals) * sdnn * sdnn
                sdnnCount += metric.acceptedIntervals
            }
            if let meanRR = metric.meanRR {
                rrSum += meanRR * Double(metric.acceptedIntervals)
                rrCount += metric.acceptedIntervals
            }
            accepted += metric.acceptedIntervals
            rejected += metric.rejectedIntervals
        }

        return HRVMetrics(
            rmssd: pairs > 0 ? (weightedSquares / Double(pairs)).squareRoot() : nil,
            // Pooled *within-reading* SDNN: the spread inside each ~60 s
            // window, not the spread across the night. Comparable to Apple's
            // per-reading SDNN, which is what it exists to check.
            sdnn: sdnnCount > 0 ? (sdnnWeighted / Double(sdnnCount)).squareRoot() : nil,
            meanRR: rrCount > 0 ? rrSum / Double(rrCount) : nil,
            acceptedIntervals: accepted,
            rejectedIntervals: rejected,
            successivePairs: pairs
        )
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let sumSquares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sumSquares / Double(values.count - 1)).squareRoot()
    }
}
