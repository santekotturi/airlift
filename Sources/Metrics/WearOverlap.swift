import Foundation

/// When each device was actually on the wrist, and how two continuous series
/// compare over only the time both were. A Watch on its charger leaves a hole
/// in Apple's heart rate; averaging across it compares Fitbit's evening
/// against no Watch evening at all. Workouts skew the other way — the Watch
/// samples every few seconds mid-workout and every few minutes otherwise, so a
/// per-sample mean is mostly workout. Both are fixed by time-weighting over
/// the shared wear window. Pure, for testability.
enum WearOverlap {
    /// Longest silence that still counts as continuous wear. Apple Watch
    /// background heart rate lands every ~5–10 minutes, sometimes a little
    /// sparser; a charge is longer than this.
    static let maxGap: TimeInterval = 30 * 60

    /// Bucket for time-weighting: each 5-minute slot counts once, however
    /// many samples fell in it.
    static let weightingBucket: TimeInterval = 5 * 60

    /// Below this much shared wear the two averages aren't comparable.
    static let minOverlap: TimeInterval = 30 * 60

    /// A reading at a moment; samples' `start` is the instant that matters.
    struct Reading {
        let date: Date
        let value: Double
    }

    /// Runs of readings with no gap longer than `maxGap` between neighbours —
    /// the stretches the device was worn. Input need not be sorted.
    static func wornRuns(_ readings: [Reading], maxGap: TimeInterval = maxGap) -> [[Reading]] {
        let sorted = readings.sorted { $0.date < $1.date }
        var runs: [[Reading]] = []
        var current: [Reading] = []
        for reading in sorted {
            if let last = current.last, reading.date.timeIntervalSince(last.date) > maxGap {
                runs.append(current)
                current = []
            }
            current.append(reading)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    static func wornIntervals(_ readings: [Reading], maxGap: TimeInterval = maxGap) -> [DateInterval] {
        wornRuns(readings, maxGap: maxGap).compactMap { run in
            guard let first = run.first, let last = run.last, last.date > first.date else { return nil }
            return DateInterval(start: first.date, end: last.date)
        }
    }

    /// Times inside both interval lists. Each list is sorted and disjoint
    /// (as `wornIntervals` produces).
    static func intersection(_ a: [DateInterval], _ b: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            let start = max(a[i].start, b[j].start)
            let end = min(a[i].end, b[j].end)
            if end > start { result.append(DateInterval(start: start, end: end)) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return result
    }

    /// Mean of per-bucket means, so a dense burst of samples weighs no more
    /// than the same span sampled sparsely.
    static func timeWeightedMean(_ readings: [Reading], bucket: TimeInterval = weightingBucket) -> Double? {
        guard !readings.isEmpty else { return nil }
        let buckets = Dictionary(grouping: readings) {
            ($0.date.timeIntervalSinceReferenceDate / bucket).rounded(.down)
        }
        let means = buckets.values.map { members in members.reduce(0) { $0 + $1.value } / Double(members.count) }
        return means.reduce(0, +) / Double(means.count)
    }

    /// The side-by-side numbers for two continuous series, restricted to the
    /// time both devices were worn.
    struct Comparison: Equatable {
        let google: Double
        let apple: Double
        /// Readings of each side that fell inside the shared window.
        let googleCount: Int
        let appleCount: Int
        let googleRange: ClosedRange<Double>
        /// Total time both were worn.
        let overlap: TimeInterval
        /// The longest stretch Google has readings but Apple has none — the
        /// Watch off the wrist — if one is long enough to matter.
        let longestAppleGap: DateInterval?
    }

    static func compare(google: [Reading], apple: [Reading]) -> Comparison? {
        let shared = intersection(wornIntervals(google), wornIntervals(apple))
        let overlap = shared.reduce(0) { $0 + $1.duration }
        guard overlap >= minOverlap else { return nil }
        let inside = { (r: Reading) in shared.contains { $0.contains(r.date) } }
        let g = google.filter(inside)
        let a = apple.filter(inside)
        guard let gMean = timeWeightedMean(g), let aMean = timeWeightedMean(a),
              let gMin = g.map(\.value).min(), let gMax = g.map(\.value).max()
        else { return nil }
        return Comparison(
            google: gMean,
            apple: aMean,
            googleCount: g.count,
            appleCount: a.count,
            googleRange: gMin...gMax,
            overlap: overlap,
            longestAppleGap: longestGap(in: apple, covered: google)
        )
    }

    /// The longest hole in `apple`'s wear while `google` was still reading —
    /// the Watch on its charger, in practice.
    static func longestGap(in apple: [Reading], covered google: [Reading]) -> DateInterval? {
        let googleWorn = wornIntervals(google)
        let appleWorn = wornIntervals(apple)
        guard !googleWorn.isEmpty else { return nil }
        // Apple's holes: between its worn intervals, plus before the first and
        // after the last, clipped to Google's span.
        let span = DateInterval(start: googleWorn.first!.start, end: googleWorn.last!.end)
        var edges = [span.start]
        for interval in appleWorn { edges += [interval.start, interval.end] }
        edges.append(span.end)
        var holes: [DateInterval] = []
        for k in stride(from: 0, to: edges.count - 1, by: 2) {
            let start = max(edges[k], span.start), end = min(edges[k + 1], span.end)
            if end > start { holes.append(DateInterval(start: start, end: end)) }
        }
        // Only the part of each hole Google actually covered counts.
        let best = holes
            .flatMap { intersection([$0], googleWorn) }
            .max { $0.duration < $1.duration }
        guard let best, best.duration > maxGap else { return nil }
        return best
    }
}

extension MetricKind {
    /// Kinds read continuously enough that gaps mean "not worn" and the
    /// comparison should be time-weighted over shared wear. Everything else
    /// is sparse spot readings, where per-sample averages are the honest read.
    var comparesOverWearOverlap: Bool { self == .heartRate }
}

extension WearOverlap {
    /// "6.2 h", "45 min" — the shared-wear span as it reads in a sentence.
    static func hoursLabel(_ duration: TimeInterval) -> String {
        duration < 3600
            ? "\(Int((duration / 60).rounded())) min"
            : String(format: "%.1f h", duration / 3600)
    }
}

extension Array where Element == MetricSample {
    var wearReadings: [WearOverlap.Reading] { map { .init(date: $0.start, value: $0.value) } }
}

extension Array where Element == QuantitySample {
    var wearReadings: [WearOverlap.Reading] { map { .init(date: $0.start, value: $0.value) } }
}
