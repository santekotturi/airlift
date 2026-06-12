import Foundation

/// One normalized quantity reading from Google Health, in the metric's
/// HealthKit unit. Instant readings have `end == start`.
struct MetricSample: Equatable, Identifiable {
    /// Google dataPoint ID — the dedup key, same contract as sleep sessions.
    let id: String
    let start: Date
    let end: Date
    let value: Double
}

/// Wire response for `GET /v4/users/me/dataTypes/<type>/dataPoints` on quantity
/// types. The envelope (`name` + `dataSource` + a payload object keyed by the
/// data type's lowerCamelCase name) is verified against a real sleep payload;
/// the payload *interior* is still a defensive best-effort — the timestamp and
/// numeric value are accepted from several plausible encodings and unparseable
/// points are dropped, not fatal.
struct QuantityDataPointsResponse: Decodable {
    let dataPoints: [QuantityDataPoint]?
    let nextPageToken: String?

    func mapped(kind: MetricKind) -> [MetricSample] {
        (dataPoints ?? []).compactMap { $0.asSample(kind: kind) }
    }

    /// Earliest payload start on this page, mirrors included — used as the
    /// stop condition when paging an unfiltered fetch back through time.
    func oldestStart(kind: MetricKind) -> Date? {
        (dataPoints ?? [])
            .compactMap { ($0.payloads[kind.googlePayloadKey] ?? $0.payloads.values.first)?.startDate }
            .min()
    }
}

struct QuantityDataPoint: Decodable {
    let name: String?
    let dataSource: WireDataSource?
    /// Payload objects by wire key — the data type's own key (e.g.
    /// `"heartRate"`) plus anything else object-shaped we don't recognize.
    let payloads: [String: QuantityPayload]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = try? container.decodeIfPresent(String.self, forKey: AnyCodingKey("name"))
        dataSource = try? container.decodeIfPresent(WireDataSource.self, forKey: AnyCodingKey("dataSource"))
        var found: [String: QuantityPayload] = [:]
        for key in container.allKeys where key.stringValue != "name" && key.stringValue != "dataSource" {
            if let payload = try? container.decode(QuantityPayload.self, forKey: key) {
                found[key.stringValue] = payload
            }
        }
        payloads = found
    }

    func asSample(kind: MetricKind) -> MetricSample? {
        // Don't bridge points Google mirrored back from Apple HealthKit.
        if dataSource?.isHealthKitMirror == true { return nil }

        guard let payload = payloads[kind.googlePayloadKey] ?? payloads.values.first else {
            Log.api.notice("\(kind.rawValue) dataPoint had no payload object")
            return nil
        }
        guard let start = payload.startDate, let raw = extractValue(kind: kind, from: payload) else {
            Log.api.notice("Skipping unparseable \(kind.rawValue) dataPoint")
            return nil
        }
        guard kind.isValidRaw(raw) else { return nil } // sentinel/no-reading values
        let end = payload.endDate ?? start
        guard end >= start else { return nil }

        // Most quantity points carry no `name` ("individual data points do not
        // need to be identified" — API docs), so the dedup ID falls back to a
        // synthetic key that is stable across re-fetches of the same data.
        let id = dataPointID(fromName: name)
            ?? "\(kind.rawValue)|\(payload.timeIdentifier)|\(raw)"
        return MetricSample(id: id, start: start, end: end, value: kind.normalize(raw))
    }

    /// Picks the value using the kind's verified field names first, falling
    /// back to the payload's generic best guess for schema drift.
    /// HRV: zero means "not measured" on the wire (Apple mirrors carry
    /// `rmssd: 0` next to a real SDNN, and vice versa), so zeros are skipped.
    private func extractValue(kind: MetricKind, from payload: QuantityPayload) -> Double? {
        let known = kind.wireValueKeys.compactMap { payload.numerics[$0] }
        if kind == .heartRateVariability {
            return (known + [payload.value].compactMap { $0 }).first { $0 > 0 }
        }
        return known.first ?? payload.value
    }
}

enum BucketAggregation {
    case average // levels (heart rate)
    case sum     // cumulative (steps, distance)
}

extension Array where Element == MetricSample {
    /// Buckets samples into fixed windows. Bucket IDs (not member IDs) become
    /// the dedup keys, so re-fetches of the same window dedupe even if the raw
    /// points differ slightly at the edges.
    func downsampled(bucket: TimeInterval, kind: MetricKind, aggregation: BucketAggregation = .average) -> [MetricSample] {
        guard !isEmpty else { return [] }
        let groups = Dictionary(grouping: self) { sample -> Date in
            let interval = (sample.start.timeIntervalSinceReferenceDate / bucket).rounded(.down) * bucket
            return Date(timeIntervalSinceReferenceDate: interval)
        }
        return groups.map { bucketStart, members in
            let total = members.reduce(0) { $0 + $1.value }
            return MetricSample(
                id: "\(kind.rawValue)|\(Int(bucket))s|\(Int(bucketStart.timeIntervalSince1970))",
                start: bucketStart,
                end: bucketStart.addingTimeInterval(bucket),
                value: aggregation == .sum ? total : total / Double(members.count)
            )
        }
        .sorted { $0.start < $1.start }
    }
}

/// Interior of a quantity payload, verified against real payloads (2026-06).
/// Three timestamp shapes exist:
/// - `interval` {startTime, endTime} — interval types (steps, distance)
/// - `sampleTime` {physicalTime} — sample types (heart rate, HRV, SpO2)
/// - `date` {year, month, day} — daily aggregates (resting HR, respiratory)
/// Values are type-specific fields, often string-encoded numbers
/// (`"beatsPerMinute": "66"`, `"count": "18"`), so every key is scanned for a
/// numeric; the kind picks its verified field, with a generic fallback.
struct QuantityPayload: Decodable {
    let interval: WireInterval?
    let time: String?
    let sampleTime: WireSampleTime?
    let date: WireCivilDate?
    /// Every numeric (or numeric-string) field on the payload, by key.
    let numerics: [String: Double]

    /// Generic fallback value when the kind's verified keys all miss.
    var value: Double? {
        if let key = Self.preferredValueKeys.first(where: { numerics[$0] != nil }) {
            return numerics[key]
        }
        // Unknown but unambiguous field name — take it and let the
        // plausibility checks judge the result.
        return numerics.count == 1 ? numerics.values.first : nil
    }

    private static let preferredValueKeys = [
        "value", "count", "millimeters", "beatsPerMinute", "bpm",
        "rootMeanSquareOfSuccessiveDifferencesMilliseconds",
        "standardDeviationMilliseconds",
        "percentage", "breathsPerMinute", "rate",
        "fpVal", "intVal",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        interval = try? container.decodeIfPresent(WireInterval.self, forKey: AnyCodingKey("interval"))
        sampleTime = try? container.decodeIfPresent(WireSampleTime.self, forKey: AnyCodingKey("sampleTime"))
        date = try? container.decodeIfPresent(WireCivilDate.self, forKey: AnyCodingKey("date"))
        time = (try? container.decodeIfPresent(String.self, forKey: AnyCodingKey("time")))
            ?? (try? container.decodeIfPresent(String.self, forKey: AnyCodingKey("timestamp")))

        let timestampKeys: Set<String> = ["interval", "sampleTime", "date", "time", "timestamp"]
        var found: [String: Double] = [:]
        for key in container.allKeys where !timestampKeys.contains(key.stringValue) {
            if let v = try? container.decode(Double.self, forKey: key) {
                found[key.stringValue] = v
            } else if let s = try? container.decode(String.self, forKey: key), let v = Double(s) {
                found[key.stringValue] = v
            } else if key.stringValue == "value",
                      let nested = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key) {
                for inner in ["fpVal", "intVal", "doubleValue"] {
                    if let v = try? nested.decodeIfPresent(Double.self, forKey: AnyCodingKey(inner)) {
                        found["value"] = v
                        break
                    }
                }
            }
        }
        numerics = found
    }

    var startDate: Date? {
        interval?.startDate
            ?? sampleTime?.physicalDate
            ?? time.flatMap { CivilTime(iso8601: $0)?.date }
            ?? date?.localDayStart
    }

    var endDate: Date? {
        interval?.endDate
            ?? sampleTime?.physicalDate
            ?? time.flatMap { CivilTime(iso8601: $0)?.date }
            ?? date?.localDayStart.map { $0.addingTimeInterval(86_400) }
    }

    /// Stable wire-time string for synthetic dedup IDs.
    var timeIdentifier: String {
        interval?.startTime
            ?? sampleTime?.physicalTime
            ?? time
            ?? date?.identifier
            ?? "?"
    }
}

/// `"sampleTime"`: an instant plus its civil offset; `physicalTime` is the
/// absolute UTC moment.
struct WireSampleTime: Decodable {
    let physicalTime: String?

    var physicalDate: Date? { physicalTime.flatMap { CivilTime(iso8601: $0)?.date } }
}

/// `"date"`: a bare civil day on daily-aggregate payloads. Resolved to the
/// local calendar day — daily summaries are about the user's day, and we have
/// no offset on the wire to do better with.
struct WireCivilDate: Decodable {
    let year: Int?
    let month: Int?
    let day: Int?

    var localDayStart: Date? {
        guard let year, let month, let day else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }

    var identifier: String {
        "\(year ?? 0)-\(month ?? 0)-\(day ?? 0)"
    }
}
