import Foundation
import HealthKit

/// Every quantity metric AirKit bridges from Google Health into HealthKit.
///
/// Adding a new metric is one new case here: the Google data-type path, the
/// HealthKit type/unit, plausibility bounds for sanity checks, and display
/// formatting all live on this enum.
///
/// Not bridgeable: ECG and Irregular Rhythm Notifications (HealthKit forbids
/// third-party writes of those types). Nutrition and GPS workout routes are
/// possible but unmapped so far.
enum MetricKind: String, CaseIterable, Identifiable {
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariability = "heart_rate_variability"
    case oxygenSaturation = "oxygen_saturation"
    case respiratoryRate = "respiratory_rate"
    case steps = "steps"
    case distance = "distance"

    var id: String { rawValue }

    /// Google Health API path: `users/me/dataTypes/<this>/dataPoints`.
    /// Endpoint IDs are kebab-case (developers.google.com/health/data-types);
    /// resting HR and respiratory rate exist only as daily aggregates.
    var googleDataTypePath: String {
        switch self {
        case .heartRate: return "heart-rate"
        case .restingHeartRate: return "daily-resting-heart-rate"
        case .heartRateVariability: return "heart-rate-variability"
        case .oxygenSaturation: return "oxygen-saturation"
        case .respiratoryRate: return "daily-respiratory-rate"
        case .steps: return "steps"
        case .distance: return "distance"
        }
    }

    /// The same type ID in snake_case — the spelling filter expressions require
    /// (`heart_rate.interval.civil_end_time >= …` against `/heart-rate/`).
    var filterMember: String {
        googleDataTypePath.replacingOccurrences(of: "-", with: "_")
    }

    /// Key of the payload object inside a dataPoint envelope — the data type's
    /// lowerCamelCase name (the sleep payload arrives under `"sleep"`).
    var googlePayloadKey: String {
        switch self {
        case .heartRate: return "heartRate"
        case .restingHeartRate: return "dailyRestingHeartRate"
        case .heartRateVariability: return "heartRateVariability"
        case .oxygenSaturation: return "oxygenSaturation"
        case .respiratoryRate: return "dailyRespiratoryRate"
        case .steps: return "steps"
        case .distance: return "distance"
        }
    }

    /// Verified wire value-field names, in preference order. HRV: Fitbit
    /// reports RMSSD only; SDNN appears on Apple-mirrored points (skipped) —
    /// kept as fallback should Fitbit start providing it.
    var wireValueKeys: [String] {
        switch self {
        case .heartRate, .restingHeartRate:
            return ["beatsPerMinute"]
        case .heartRateVariability:
            return ["rootMeanSquareOfSuccessiveDifferencesMilliseconds", "standardDeviationMilliseconds"]
        case .oxygenSaturation:
            return ["percentage"]
        case .respiratoryRate:
            return ["breathsPerMinute"]
        case .steps:
            return ["count"]
        case .distance:
            return ["millimeters"]
        }
    }

    var displayName: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .restingHeartRate: return "Resting HR"
        case .heartRateVariability: return "HRV"
        case .oxygenSaturation: return "SpO2"
        case .respiratoryRate: return "Respiratory rate"
        case .steps: return "Steps"
        case .distance: return "Distance"
        }
    }

    var systemImage: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .restingHeartRate: return "heart.circle"
        case .heartRateVariability: return "waveform.path.ecg"
        case .oxygenSaturation: return "lungs.fill"
        case .respiratoryRate: return "wind"
        case .steps: return "figure.walk"
        case .distance: return "figure.walk.motion"
        }
    }

    /// NOTE on HRV: Fitbit computes RMSSD while HealthKit's field is SDNN.
    /// They correlate but are not the same statistic — values are written as-is
    /// with that caveat (matches what commercial sync apps do).
    var hkIdentifier: HKQuantityTypeIdentifier {
        switch self {
        case .heartRate: return .heartRate
        case .restingHeartRate: return .restingHeartRate
        case .heartRateVariability: return .heartRateVariabilitySDNN
        case .oxygenSaturation: return .oxygenSaturation
        case .respiratoryRate: return .respiratoryRate
        case .steps: return .stepCount
        case .distance: return .distanceWalkingRunning
        }
    }

    var hkUnit: HKUnit {
        switch self {
        case .heartRate, .restingHeartRate, .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariability:
            return HKUnit.secondUnit(with: .milli)
        case .oxygenSaturation:
            return HKUnit.percent() // HealthKit convention: 0.97 == 97%
        case .steps:
            return HKUnit.count()
        case .distance:
            return HKUnit.meter()
        }
    }

    /// True when daily values accumulate (sum) rather than read as a level (avg).
    var isCumulative: Bool { self == .steps || self == .distance }

    /// Non-nil when Google and Apple report different statistics for this
    /// metric, so a numeric comparison can't pass or fail — only inform.
    /// HRV: Fitbit reports RMSSD, HealthKit stores SDNN; RMSSD typically runs
    /// well below SDNN for the same night, so a delta is expected.
    var appleComparisonCaveat: String? {
        self == .heartRateVariability ? "Google RMSSD vs Apple SDNN — different statistics" : nil
    }

    /// Bucket width for downsampling before staging/writing, or nil to keep
    /// raw samples. Fitbit Air records heart rate every ~3s (~28k points/day) —
    /// far denser than HealthKit conventions; minute averages match Apple
    /// Watch density and keep charts and the Health database sane.
    var downsampleBucketSeconds: TimeInterval? {
        self == .heartRate ? 60 : nil
    }

    /// Rejects known-invalid wire values before they become samples.
    /// Fitbit emits SpO2 of exactly 50 as a "no valid reading" sentinel
    /// (observed scattered through real nights; the device's own display
    /// floor is 80%, and a true 50% SpO2 would be a medical emergency).
    func isValidRaw(_ raw: Double) -> Bool {
        switch self {
        case .oxygenSaturation: return normalize(raw) > 0.5
        default: return true
        }
    }

    /// Plausible bounds (in `hkUnit`) for the sanity checker, per sample.
    var plausibleRange: ClosedRange<Double> {
        switch self {
        case .heartRate: return 25...250
        case .restingHeartRate: return 25...120
        case .heartRateVariability: return 5...300
        case .oxygenSaturation: return 0.7...1.0
        case .respiratoryRate: return 4...40
        case .steps: return 0...50_000
        case .distance: return 0...200_000 // meters; ultra-distance days happen
        }
    }

    /// Converts a raw Google value into the HealthKit unit.
    /// SpO2: Google reports percent points (97); HealthKit wants a fraction (0.97).
    /// Distance: Google's wire unit is millimeters; HealthKit gets meters.
    func normalize(_ raw: Double) -> Double {
        switch self {
        case .oxygenSaturation: return raw > 1.5 ? raw / 100 : raw
        case .distance: return raw / 1000
        default: return raw
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .oxygenSaturation: return String(format: "%.0f%%", value * 100)
        case .heartRateVariability: return String(format: "%.0f ms", value)
        case .heartRate, .restingHeartRate, .respiratoryRate: return String(format: "%.0f bpm", value)
        case .steps: return String(format: "%.0f", value)
        case .distance:
            return value >= 1000
                ? String(format: "%.2f km", value / 1000)
                : String(format: "%.0f m", value)
        }
    }
}
