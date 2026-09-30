import Foundation

/// One night's vitals on both devices — the rest of what Today shows beside
/// sleep. Each side is only what that device recorded: the Watch's own
/// samples, and Fitbit's as Airlift or Google Health wrote them.
struct NightVitals: Equatable {
    struct Row: Identifiable, Equatable {
        enum Kind: String { case hrv, sleepingHR, restingHR, respiratoryRate, oxygen, steps }

        let kind: Kind
        let watch: Double?
        let fitbit: Double?
        /// False when the two are different statistics (Watch SDNN against
        /// Fitbit RMSSD) — shown side by side, never subtracted.
        var comparable = true

        var id: String { kind.rawValue }

        var name: String {
            switch kind {
            case .hrv: comparable ? "HRV" : "HRV (Watch SDNN)"
            case .sleepingHR: "Heart rate asleep"
            case .restingHR: "Resting HR"
            case .respiratoryRate: "Breathing rate"
            case .oxygen: "Blood oxygen"
            case .steps: "Steps the day before"
            }
        }

        func format(_ value: Double) -> String {
            switch kind {
            case .hrv: String(format: "%.0f ms", value)
            case .sleepingHR, .restingHR: String(format: "%.0f bpm", value)
            case .respiratoryRate: String(format: "%.1f /min", value)
            case .oxygen: String(format: "%.0f%%", value * 100)
            case .steps: value.formatted(.number.precision(.fractionLength(0)))
            }
        }

        /// Fitbit − Watch, in the row's units; nil unless both exist and mean
        /// the same thing.
        var difference: String? {
            guard comparable, let watch, let fitbit else { return nil }
            let delta = fitbit - watch
            let sign = delta >= 0 ? "+" : "−"
            switch kind {
            case .oxygen: return sign + String(format: "%.0f pt", abs(delta) * 100)
            case .respiratoryRate: return sign + String(format: "%.1f", abs(delta))
            case .steps: return sign + abs(delta).formatted(.number.precision(.fractionLength(0)))
            default: return sign + String(format: "%.0f", abs(delta))
            }
        }
    }

    let rows: [Row]

    static let empty = NightVitals(rows: [])

    /// - Parameters:
    ///   - hrv: the night's whole-sleep HRV from the Recovery engine.
    ///   - asleep: when the night's sleep ran, for heart rate and the Watch's
    ///     overnight readings; nil falls back to the whole night window.
    ///   - night: the 6pm→6pm window the night is filed under.
    ///   - wakeDay: the civil day the night ends on — resting heart rate is a
    ///     daily figure on both devices.
    static func build(
        hrv: NightRecovery?,
        heartRate: [HRSample],
        restingHR: [QuantitySample],
        respiratoryRate: [QuantitySample],
        oxygen: [QuantitySample],
        steps: (watch: Double?, fitbit: Double?) = (nil, nil),
        asleep: DateInterval?,
        night: DateInterval,
        wakeDay: DateInterval
    ) -> NightVitals {
        var rows: [Row] = []

        if let hrv {
            let watch = hrv.appleNativeRMSSD ?? hrv.appleSDNN
            rows.append(Row(
                kind: .hrv,
                watch: watch?.value,
                fitbit: hrv.fitbitRMSSD?.value,
                comparable: hrv.appleNativeRMSSD != nil || watch == nil
            ))
        }

        let sleepWindow = asleep ?? night
        rows.append(Row(
            kind: .sleepingHR,
            watch: mean(heartRate.filter { $0.fromAppleDevice && sleepWindow.contains($0.date) }.map(\.bpm)),
            fitbit: mean(heartRate.filter { $0.fromGoogleHealth && sleepWindow.contains($0.date) }.map(\.bpm))
        ))
        rows.append(pair(.restingHR, restingHR, watchWindow: wakeDay, fitbitWindow: wakeDay))
        // The Watch samples these through the night; Google Health writes one
        // nightly summary, stamped anywhere in the night window.
        rows.append(pair(.respiratoryRate, respiratoryRate, watchWindow: sleepWindow, fitbitWindow: night))
        rows.append(pair(.oxygen, oxygen, watchWindow: sleepWindow, fitbitWindow: night))
        rows.append(Row(kind: .steps, watch: steps.watch, fitbit: steps.fitbit))

        return NightVitals(rows: rows.filter { $0.watch != nil || $0.fitbit != nil })
    }

    private static func pair(
        _ kind: Row.Kind, _ samples: [QuantitySample], watchWindow: DateInterval, fitbitWindow: DateInterval
    ) -> Row {
        Row(
            kind: kind,
            watch: mean(samples.filter { $0.fromAppleDevice && watchWindow.contains($0.start) }.map(\.value)),
            fitbit: mean(samples.filter { $0.fromGoogleHealth && fitbitWindow.contains($0.start) }.map(\.value))
        )
    }

    private static func mean(_ values: [Double]) -> Double? {
        RecoveryStats.mean(values.filter(\.isFinite))
    }
}
