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

    var isHealthKitMirror: Bool { platform == "HEALTH_KIT" }
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
