import Foundation

// Shared wire fragments for Google Health `dataPoints` responses. Verified
// against a real sleep payload (2026-06): every data point is an envelope of
// `name` + `dataSource` + one payload object keyed by the data type's
// lowerCamelCase name (e.g. `"sleep": {...}`, `"heartRate": {...}`).

/// `"name": "users/<uid>/dataTypes/<type>/dataPoints/<id>"` — the stable
/// dataPoint ID is the last path component.
func dataPointID(fromName name: String?) -> String? {
    guard let last = name?.split(separator: "/").last, !last.isEmpty else { return nil }
    return String(last)
}

/// Where a point originated. Google mirrors Apple HealthKit data back through
/// the Health API (`platform: "HEALTH_KIT"`); bridging those points would
/// re-import the user's own Apple samples, so mappers skip them.
struct WireDataSource: Decodable {
    let platform: String?
    let recordingMethod: String?
    let device: WireDevice?

    var isHealthKitMirror: Bool { platform == "HEALTH_KIT" }

    /// Best human label for the Fitbit-side device on this point, or nil.
    /// Real 2026-06 payloads usually carry `device: {}`; exercise points add
    /// `formFactor: "FITNESS_BAND"`. The docs promise `displayName`
    /// ("Charge 6") — honored first whenever Google starts sending it.
    var fitbitDeviceLabel: String? {
        guard platform == "FITBIT", let device else { return nil }
        if let name = device.displayName, !name.isEmpty { return name }
        if let model = device.model, !model.isEmpty { return model }
        switch device.formFactor {
        case "FITNESS_BAND": return DeviceLabel.genericBand
        case "SMARTWATCH", "WATCH": return DeviceLabel.genericWatch
        default: return nil
        }
    }
}

/// `"device"`: hardware details on a data source — sparsely populated pre-GA.
struct WireDevice: Decodable {
    let displayName: String?
    let model: String?
    let manufacturer: String?
    let formFactor: String?
}

/// Merge policy for the detected device label: an explicit name (model /
/// displayName) always wins; a form-factor generic only fills an empty slot.
enum DeviceLabel {
    static let genericBand = "Fitbit band"
    static let genericWatch = "Fitbit watch"
    /// Shown when nothing has been detected and the user set no override.
    static let fallback = "Fitbit"

    static func isGeneric(_ label: String) -> Bool {
        label == genericBand || label == genericWatch
    }

    /// Returns the label to keep given what's stored and what a page showed.
    static func merge(current: String?, candidate: String?) -> String? {
        guard let candidate else { return current }
        guard let current else { return candidate }
        if isGeneric(current) && !isGeneric(candidate) { return candidate }
        return current
    }
}

/// `"interval"`: UTC instants plus the civil offset in effect when recorded.
/// `startTime`/`endTime` are already absolute (RFC 3339, `Z`), so the offsets
/// are display-only and ignored here.
struct WireInterval: Decodable {
    let startTime: String?
    let endTime: String?

    var startDate: Date? { startTime.flatMap { CivilTime(iso8601: $0)?.date } }
    var endDate: Date? { endTime.flatMap { CivilTime(iso8601: $0)?.date } }
}

/// Coding key over arbitrary strings — used to find the payload object whose
/// key varies by data type.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
