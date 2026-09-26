import Foundation

/// Method-comparison statistics for two devices measuring the same person.
///
/// Correlation alone is the classic mistake in device-validation work: two
/// instruments can correlate at r = 0.95 while one reads 30% high. So the
/// summary carries three separable questions —
///
/// * **Do they rank nights the same?** Spearman ρ, with a Fisher interval.
/// * **Do they read the same value?** Ratio bias and limits of agreement.
/// * **Would swapping one for the other change a decision?** Change agreement
///   on consecutive nights, which strips each device's constant offset and each
///   person's baseline and leaves only the night-to-night signal a recovery app
///   actually reports.
///
/// And one that decides whether any of the above can be believed: reliability.
/// A metric whose nightly wobble is mostly measurement error cannot support a
/// decision no matter how well it correlates, and it caps how high the
/// correlation could ever have gone.
///
/// HRV is approximately log-normal, so every statistic here is computed on
/// log values unless stated otherwise.
enum RecoveryStats {

    // MARK: - Summary

    /// Everything needed to judge whether device B can stand in for device A.
    struct AgreementSummary: Equatable {
        let n: Int
        /// Rank agreement on nightly levels.
        let spearman: Double?
        let spearmanCILow: Double?
        let spearmanCIHigh: Double?
        let pearson: Double?
        /// Lin's concordance — penalises scatter *and* systematic offset.
        let ccc: Double?
        /// Bias as a percentage: "reads 24% high".
        let ratioBiasPct: Double?
        /// 95% limits of agreement, also as percentages.
        let ratioLoALowPct: Double?
        let ratioLoAHighPct: Double?
        /// Rank agreement on consecutive-night changes.
        let changeSpearman: Double?
        let changeN: Int

        static let insufficient = AgreementSummary(
            n: 0, spearman: nil, spearmanCILow: nil, spearmanCIHigh: nil,
            pearson: nil, ccc: nil, ratioBiasPct: nil,
            ratioLoALowPct: nil, ratioLoAHighPct: nil,
            changeSpearman: nil, changeN: 0
        )

        /// Below this the interval is so wide the point estimate says nothing.
        /// Reported rather than hidden — the count is part of the finding.
        var isUnderpowered: Bool { n < 20 }
    }

    /// One night's paired reading.
    struct PairedNight: Equatable {
        let night: Date
        let reference: Double
        let target: Double
    }

    /// Full comparison of `target` against `reference` across nights.
    static func compare(_ pairs: [PairedNight]) -> AgreementSummary {
        let usable = pairs.filter {
            $0.reference.isFinite && $0.target.isFinite && $0.reference > 0 && $0.target > 0
        }
        guard usable.count >= 3 else {
            return AgreementSummary(
                n: usable.count, spearman: nil, spearmanCILow: nil, spearmanCIHigh: nil,
                pearson: nil, ccc: nil, ratioBiasPct: nil,
                ratioLoALowPct: nil, ratioLoAHighPct: nil,
                changeSpearman: nil, changeN: 0
            )
        }
        let reference = usable.map(\.reference)
        let target = usable.map(\.target)
        let logReference = reference.map(log)
        let logTarget = target.map(log)

        let rho = spearman(reference, target)
        let ci = rho.flatMap { fisherInterval($0, n: usable.count) }

        // Bias and limits from differenced logs: expressed as a ratio they
        // travel across the whole range, which an absolute millisecond bias
        // does not.
        let logDiff = zip(logTarget, logReference).map { target, reference in target - reference }
        let meanLogDiff = mean(logDiff)
        let sdLogDiff = standardDeviation(logDiff)
        let loa = zip2(meanLogDiff, sdLogDiff)

        let change = changeAgreement(usable)

        return AgreementSummary(
            n: usable.count,
            spearman: rho,
            spearmanCILow: ci?.low,
            spearmanCIHigh: ci?.high,
            pearson: pearson(logReference, logTarget),
            ccc: concordance(logReference, logTarget),
            ratioBiasPct: meanLogDiff.map { (exp($0) - 1) * 100 },
            ratioLoALowPct: loa.map { (exp($0.0 - 1.96 * $0.1) - 1) * 100 },
            ratioLoAHighPct: loa.map { (exp($0.0 + 1.96 * $0.1) - 1) * 100 },
            changeSpearman: change.rho,
            changeN: change.n
        )
    }

    /// Agreement on night-to-night *changes* rather than levels.
    ///
    /// Only consecutive nights contribute: a "change" spanning a week-long gap
    /// is not the quantity a recovery app reports. This is usually the harder
    /// and more decision-relevant test.
    static func changeAgreement(
        _ pairs: [PairedNight],
        maxGapDays: Int = 1,
        calendar: Calendar = .current
    ) -> (rho: Double?, n: Int) {
        let sorted = pairs.sorted { $0.night < $1.night }
        var referenceDeltas: [Double] = []
        var targetDeltas: [Double] = []
        for (previous, current) in zip(sorted, sorted.dropFirst()) {
            let days = calendar.dateComponents([.day], from: previous.night, to: current.night).day ?? .max
            guard days <= maxGapDays, days > 0 else { continue }
            referenceDeltas.append(log(current.reference) - log(previous.reference))
            targetDeltas.append(log(current.target) - log(previous.target))
        }
        guard referenceDeltas.count >= 3 else { return (nil, referenceDeltas.count) }
        return (spearman(referenceDeltas, targetDeltas), referenceDeltas.count)
    }

    // MARK: - Reliability

    /// Split-half reliability of a nightly series, Spearman-Brown corrected.
    ///
    /// Each night's samples are split into two interleaved halves and each half
    /// aggregated on its own; correlating the halves across nights measures how
    /// much of the nightly value is signal rather than the device arguing with
    /// itself. Interleaved rather than first-half/second-half so a within-night
    /// trend — HRV rises through the night — does not masquerade as noise.
    ///
    /// The correction undoes the fact that each half saw only half the data:
    ///
    ///     reliability = 2r / (1 + r)
    static func splitHalfReliability(_ halves: [(a: Double, b: Double)]) -> Double? {
        let usable = halves.filter { $0.a.isFinite && $0.b.isFinite && $0.a > 0 && $0.b > 0 }
        guard usable.count >= 4 else { return nil }
        guard let r = pearson(usable.map { log($0.a) }, usable.map { log($0.b) }) else { return nil }
        guard r > -1 else { return nil }
        let corrected = 2 * r / (1 + r)
        // Sampling noise can push the estimate outside [0, 1]; clamp rather
        // than report an impossible reliability.
        return min(max(corrected, 0), 1)
    }

    /// The highest correlation two metrics could show given their own
    /// reliabilities — `sqrt(rₐ · r_b)`.
    ///
    /// Worth reporting next to every observed correlation: a ρ of 0.73 against
    /// a ceiling of 0.73 is perfect agreement measured through noisy
    /// instruments, not mediocre agreement.
    static func attenuationCeiling(_ first: Double?, _ second: Double?) -> Double? {
        guard let first, let second, first > 0, second > 0 else { return nil }
        return (first * second).squareRoot()
    }

    /// The observed correlation with measurement noise divided out — what the
    /// two metrics would correlate at if both were measured perfectly.
    /// Capped at 1: the estimate can exceed it when reliabilities are
    /// themselves noisy, and a correlation above 1 is not a finding.
    static func disattenuated(_ observed: Double?, _ first: Double?, _ second: Double?) -> Double? {
        guard let observed, let ceiling = attenuationCeiling(first, second), ceiling > 0 else { return nil }
        return min(observed / ceiling, 1)
    }

    // MARK: - Correlation

    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        let mx = mean(x), my = mean(y)
        guard let mx, let my else { return nil }
        var covariance = 0.0, varX = 0.0, varY = 0.0
        for (a, b) in zip(x, y) {
            let dx = a - mx, dy = b - my
            covariance += dx * dy
            varX += dx * dx
            varY += dy * dy
        }
        guard varX > 0, varY > 0 else { return nil }
        return covariance / (varX * varY).squareRoot()
    }

    /// Pearson on ranks, with ties averaged — robust to the outlier nights that
    /// a wrist tracker produces regularly.
    static func spearman(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        return pearson(ranks(x), ranks(y))
    }

    /// Lin's concordance correlation on log values: how close the pairs lie to
    /// the identity line, not merely to *a* line.
    static func concordance(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        guard let mx = mean(x), let my = mean(y) else { return nil }
        let n = Double(x.count)
        let varX = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) } / n
        let varY = y.reduce(0) { $0 + ($1 - my) * ($1 - my) } / n
        let covariance = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / n
        let denominator = varX + varY + (mx - my) * (mx - my)
        guard denominator > 0 else { return nil }
        return 2 * covariance / denominator
    }

    /// 95% interval for a correlation via the Fisher z transform.
    ///
    /// An interval rather than a p-value on purpose. With ~40 nights the
    /// question is never "is ρ exactly zero" — it is "how much of the range is
    /// still consistent with the data", and for a one-person series a p-value
    /// invites a certainty the sample size does not support.
    static func fisherInterval(_ r: Double, n: Int, z: Double = 1.96) -> (low: Double, high: Double)? {
        guard n > 3, r.isFinite, abs(r) < 1 else { return nil }
        let zr = atanh(r)
        let se = 1.0 / Double(n - 3).squareRoot()
        return (tanh(zr - z * se), tanh(zr + z * se))
    }

    /// Fractional ranks, ties sharing their average — 1, 2.5, 2.5, 4.
    static func ranks(_ values: [Double]) -> [Double] {
        let ordered = values.enumerated().sorted { $0.element < $1.element }
        var result = [Double](repeating: 0, count: values.count)
        var index = 0
        while index < ordered.count {
            var last = index
            while last + 1 < ordered.count, ordered[last + 1].element == ordered[index].element {
                last += 1
            }
            let averageRank = Double(index + last) / 2 + 1
            for position in index...last {
                result[ordered[position].offset] = averageRank
            }
            index = last + 1
        }
        return result
    }

    // MARK: - Descriptives

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1, let mean = mean(values) else { return nil }
        let sumSquares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sumSquares / Double(values.count - 1)).squareRoot()
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Both-or-nothing pairing of two optionals, so a derived statistic is
    /// `nil` unless every input it needs exists.
    private static func zip2(_ first: Double?, _ second: Double?) -> (Double, Double)? {
        guard let first, let second else { return nil }
        return (first, second)
    }
}
