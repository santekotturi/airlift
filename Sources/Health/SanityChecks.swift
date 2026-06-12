import Foundation

/// Outcome of one validation check on a Google sleep session.
struct CheckResult: Equatable, Hashable, Identifiable {
    enum Severity: Equatable, Hashable {
        case pass
        case info
        case warn
        case fail
    }

    let name: String
    let severity: Severity
    let detail: String

    var id: String { name }
}

/// Pure validation of a Google sleep session — internally consistent, and
/// plausible against Apple Watch data for the same night when available.
/// No I/O so every rule is unit-testable; thresholds are tuning knobs surfaced
/// as parameters with defaults.
enum SanityChecks {
    static func run(
        google: SleepSession,
        appleSleep: [AppleSleepSegment],
        heartRate: [HRSample]
    ) -> [CheckResult] {
        var results: [CheckResult] = [
            duration(google),
            segmentBounds(google),
            segmentOverlap(google),
            stageCoverage(google),
        ]
        results.append(contentsOf: appleComparison(google: google, apple: appleSleep))
        if let hr = heartRateSummary(google: google, heartRate: heartRate) {
            results.append(hr)
        }
        return results
    }

    // MARK: - Internal consistency

    /// Total session length should be a plausible night (or nap).
    static func duration(
        _ session: SleepSession,
        minHours: Double = 0.5,
        maxHours: Double = 14
    ) -> CheckResult {
        let hours = session.end.timeIntervalSince(session.start) / 3600
        let formatted = String(format: "%.1f h", hours)
        if hours < minHours {
            return CheckResult(name: "Duration", severity: .fail, detail: "Implausibly short: \(formatted)")
        }
        if hours > maxHours {
            return CheckResult(name: "Duration", severity: .warn, detail: "Unusually long: \(formatted)")
        }
        return CheckResult(name: "Duration", severity: .pass, detail: formatted)
    }

    /// Every stage segment must fall within the session window (small tolerance).
    static func segmentBounds(
        _ session: SleepSession,
        tolerance: TimeInterval = 300
    ) -> CheckResult {
        let lower = session.start.addingTimeInterval(-tolerance)
        let upper = session.end.addingTimeInterval(tolerance)
        let outliers = session.stages.filter { $0.start < lower || $0.end > upper }
        if outliers.isEmpty {
            return CheckResult(name: "Segment bounds", severity: .pass, detail: "All \(session.stages.count) segments inside the session window")
        }
        return CheckResult(name: "Segment bounds", severity: .fail, detail: "\(outliers.count) segment(s) outside the session window — timezone/offset bug?")
    }

    /// Stage segments shouldn't overlap each other.
    static func segmentOverlap(
        _ session: SleepSession,
        tolerance: TimeInterval = 60
    ) -> CheckResult {
        let sorted = session.stages.sorted { $0.start < $1.start }
        var overlaps = 0
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.start < a.end.addingTimeInterval(-tolerance) {
            overlaps += 1
        }
        if overlaps == 0 {
            return CheckResult(name: "Segment overlap", severity: .pass, detail: "No overlapping segments")
        }
        return CheckResult(name: "Segment overlap", severity: .warn, detail: "\(overlaps) overlapping pair(s) — would double-count in Health")
    }

    /// Stage segments should roughly tile the session.
    static func stageCoverage(
        _ session: SleepSession,
        minFraction: Double = 0.7,
        maxFraction: Double = 1.05
    ) -> CheckResult {
        let sessionLength = session.end.timeIntervalSince(session.start)
        guard sessionLength > 0 else {
            return CheckResult(name: "Stage coverage", severity: .fail, detail: "Zero-length session")
        }
        let covered = session.stages.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        let fraction = covered / sessionLength
        let percent = String(format: "%.0f%%", fraction * 100)
        if fraction < minFraction {
            return CheckResult(name: "Stage coverage", severity: .warn, detail: "Stages cover only \(percent) of the session — gaps in data")
        }
        if fraction > maxFraction {
            return CheckResult(name: "Stage coverage", severity: .warn, detail: "Stages cover \(percent) — overlaps or out-of-window segments")
        }
        return CheckResult(name: "Stage coverage", severity: .pass, detail: "Stages cover \(percent) of the session")
    }

    // MARK: - Apple Watch cross-check

    static func appleComparison(
        google: SleepSession,
        apple: [AppleSleepSegment],
        minOverlapFraction: Double = 0.5,
        maxAsleepDeltaMinutes: Double = 90
    ) -> [CheckResult] {
        let appleAsleep = apple.filter(\.isAsleep)
        guard !appleAsleep.isEmpty else {
            return [CheckResult(name: "Apple Watch", severity: .info, detail: "No Apple sleep data for this night — nothing to compare")]
        }

        var results: [CheckResult] = []

        // Window overlap: do the two sources agree this night happened here?
        let appleStart = appleAsleep.map(\.start).min()!
        let appleEnd = appleAsleep.map(\.end).max()!
        let overlapStart = max(google.start, appleStart)
        let overlapEnd = min(google.end, appleEnd)
        let overlap = max(0, overlapEnd.timeIntervalSince(overlapStart))
        let googleLength = google.end.timeIntervalSince(google.start)
        let fraction = googleLength > 0 ? overlap / googleLength : 0
        let percent = String(format: "%.0f%%", fraction * 100)
        if fraction < minOverlapFraction {
            results.append(CheckResult(name: "Window overlap", severity: .warn, detail: "Only \(percent) of the Google session overlaps Apple's — check timezone handling"))
        } else {
            results.append(CheckResult(name: "Window overlap", severity: .pass, detail: "\(percent) of the Google session overlaps Apple's"))
        }

        // Total-asleep delta between sources.
        let googleAsleep = google.stages
            .filter { $0.stage != .wake && $0.stage != .restless }
            .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        let appleAsleepTotal = appleAsleep.reduce(0.0) { $0 + $1.duration }
        let deltaMinutes = abs(googleAsleep - appleAsleepTotal) / 60
        let detail = String(
            format: "Google %.1f h vs Apple %.1f h asleep (Δ %.0f min)",
            googleAsleep / 3600, appleAsleepTotal / 3600, deltaMinutes
        )
        if deltaMinutes > maxAsleepDeltaMinutes {
            results.append(CheckResult(name: "Asleep total", severity: .warn, detail: detail))
        } else {
            results.append(CheckResult(name: "Asleep total", severity: .pass, detail: detail))
        }

        return results
    }

    // MARK: - Quantity metrics

    /// Validates one day's batch of a quantity metric, against Apple data for
    /// the same window when available. For cumulative kinds, pass `appleTotal`
    /// (HealthKit's source-deduplicated day sum) — summing raw `apple` samples
    /// double-counts overlapping iPhone/Watch data.
    static func runMetric(
        kind: MetricKind,
        samples: [MetricSample],
        apple: [QuantitySample],
        appleTotal: Double? = nil,
        maxDeltaFraction: Double = 0.3
    ) -> [CheckResult] {
        var results: [CheckResult] = []

        results.append(CheckResult(
            name: "Samples",
            severity: samples.isEmpty ? .fail : .info,
            detail: "\(samples.count) Google sample(s)"
        ))
        guard !samples.isEmpty else { return results }

        // Range plausibility (catches unit mix-ups like SpO2 97 vs 0.97).
        let outliers = samples.filter { !kind.plausibleRange.contains($0.value) }
        if outliers.isEmpty {
            results.append(CheckResult(name: "Value range", severity: .pass, detail: "All values within plausible \(kind.displayName) range"))
        } else {
            let example = kind.format(outliers[0].value)
            results.append(CheckResult(name: "Value range", severity: .warn, detail: "\(outliers.count) value(s) out of range (e.g. \(example)) — unit mismatch?"))
        }

        // Apple cross-check: totals for cumulative metrics, averages otherwise.
        guard !apple.isEmpty else {
            results.append(CheckResult(name: "Apple Watch", severity: .info, detail: "No Apple \(kind.displayName) data for this day"))
            return results
        }

        let googleValue: Double
        let appleValue: Double
        let comparison: String
        if kind.isCumulative {
            googleValue = samples.reduce(0) { $0 + $1.value }
            appleValue = appleTotal ?? apple.reduce(0) { $0 + $1.value }
            comparison = appleTotal != nil ? "totals, Apple deduplicated" : "totals"
        } else {
            googleValue = samples.reduce(0) { $0 + $1.value } / Double(samples.count)
            appleValue = apple.reduce(0) { $0 + $1.value } / Double(apple.count)
            comparison = "averages"
        }
        let detail = "Google \(kind.format(googleValue)) vs Apple \(kind.format(appleValue)) (\(comparison))"
        if let caveat = kind.appleComparisonCaveat {
            results.append(CheckResult(name: "Apple comparison", severity: .info, detail: "\(detail) — \(caveat)"))
            return results
        }
        let reference = max(abs(appleValue), .leastNonzeroMagnitude)
        if abs(googleValue - appleValue) / reference > maxDeltaFraction {
            results.append(CheckResult(name: "Apple comparison", severity: .warn, detail: detail))
        } else {
            results.append(CheckResult(name: "Apple comparison", severity: .pass, detail: detail))
        }

        return results
    }

    // MARK: - Heart rate (informational)

    static func heartRateSummary(google: SleepSession, heartRate: [HRSample]) -> CheckResult? {
        let inSession = heartRate.filter { $0.date >= google.start && $0.date <= google.end }
        guard !inSession.isEmpty else { return nil }
        let values = inSession.map(\.bpm)
        let detail = String(
            format: "%d readings · min %.0f / avg %.0f / max %.0f bpm",
            inSession.count, values.min()!, values.reduce(0, +) / Double(values.count), values.max()!
        )
        return CheckResult(name: "Overnight HR", severity: .info, detail: detail)
    }
}
