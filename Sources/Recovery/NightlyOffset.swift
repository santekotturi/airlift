import Foundation

/// How two devices' nightly numbers relate when one reads on a different
/// scale. Fitbit's nightly HRV runs a steady ~20–25% under Apple's Recovery
/// HRV; a raw percent on every row says "they disagree every night" when the
/// real story is "same trend, different scale". This finds the typical ratio
/// and flags only the nights that break it. Pure, for testability.
struct NightlyOffset: Equatable {
    /// Median of other ÷ reference across nights that have both.
    let typicalRatio: Double
    /// Pearson correlation of the paired nights — whether they move together.
    let correlation: Double?
    let pairedNights: Int

    /// Fewer paired nights than this and a "typical" gap means little.
    static let minimumNights = 5
    /// A night within this of the typical ratio reads as usual.
    static let usualBand = 0.10

    init?(pairs: [(reference: Double, other: Double)]) {
        let valid = pairs.filter { $0.reference > 0 && $0.other > 0 && $0.reference.isFinite && $0.other.isFinite }
        guard valid.count >= Self.minimumNights else { return nil }
        let ratios = valid.map { $0.other / $0.reference }.sorted()
        let mid = ratios.count / 2
        typicalRatio = ratios.count.isMultiple(of: 2) ? (ratios[mid - 1] + ratios[mid]) / 2 : ratios[mid]
        correlation = Self.pearson(valid.map(\.reference), valid.map(\.other))
        pairedNights = valid.count
    }

    /// How far `other` sits from what the typical ratio predicts, as a
    /// fraction (−0.07 = 7% lower than usual); nil when it's within the
    /// usual band or either value is missing.
    func unusualDeviation(reference: Double?, other: Double?) -> Double? {
        guard let reference, let other, reference > 0 else { return nil }
        let deviation = other / (reference * typicalRatio) - 1
        return abs(deviation) > Self.usualBand ? deviation : nil
    }

    /// "Fitbit reads ~23% lower than Apple, night after night — same trend,
    /// different scale."
    func summary(other: String, reference: String) -> String {
        let percent = Int(((typicalRatio - 1) * 100).rounded())
        guard abs(percent) >= 5 else {
            return "\(other) and \(reference) read about the same, night after night."
        }
        let scale = "\(other) reads ~\(abs(percent))% \(percent < 0 ? "lower" : "higher") than \(reference)"
        if let correlation, correlation >= 0.7 {
            return "\(scale), night after night — same trend, different scale."
        }
        return "\(scale) on a typical night, though the two don't rise and fall together reliably."
    }

    private static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) {
            sxy += (a - mx) * (b - my); sxx += (a - mx) * (a - mx); syy += (b - my) * (b - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }
}
