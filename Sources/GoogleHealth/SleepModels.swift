import Foundation

// MARK: - Domain model (what the rest of the app consumes)

/// One finalized sleep session, normalized to absolute `Date`s.
struct SleepSession: Equatable, Hashable, Identifiable {
    /// Stable Google dataPoint ID — the dedup key (PRD §8).
    let id: String
    let start: Date
    let end: Date
    let stages: [SleepStageSegment]

    /// In-progress nights (no end) are ignored upstream; this is a guard.
    var isComplete: Bool { end > start && !stages.isEmpty }
}

/// A single contiguous stage interval within a session.
struct SleepStageSegment: Equatable, Hashable {
    let stage: SleepStage
    let start: Date
    let end: Date
}

/// Fitbit/Google sleep stage. Unknown wire values decode to `.unknown` and are
/// mapped to `.asleepUnspecified` in HealthKit (PRD §9 — schema drift tolerance).
enum SleepStage: String, Equatable, CaseIterable {
    case wake
    case light
    case deep
    case rem
    case asleep      // classic (non-staged) logs
    case restless    // classic logs
    case unknown

    /// Real wire values are SCREAMING_CASE (`AWAKE`, `LIGHT`, `DEEP`, `REM`);
    /// Google's awake stage is spelled `AWAKE`, our case is `wake`.
    init(wireValue: String) {
        switch wireValue.lowercased() {
        case "awake", "wake": self = .wake
        case "light": self = .light
        case "deep": self = .deep
        case "rem": self = .rem
        case "asleep": self = .asleep
        case "restless": self = .restless
        default: self = .unknown
        }
    }
}

// MARK: - Civil time

/// A Google "civil time": a wall-clock instant plus the UTC offset that was in
/// effect where/when it was recorded. We must resolve to an absolute `Date` using
/// *that* offset, not the phone's current time zone — critical when travelling
/// across zones (PRD §9).
struct CivilTime: Equatable {
    let date: Date

    /// Accepts an RFC 3339 / ISO 8601 string that carries its own offset, e.g.
    /// `2026-06-07T23:14:05-07:00` or `...Z`.
    init?(iso8601 string: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: string) {
            self.date = d
            return
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: string) {
            self.date = d
            return
        }
        return nil
    }

    /// Builds an absolute `Date` from wall-clock components plus an explicit
    /// offset in seconds (the structured-civil-time shape).
    init?(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, utcOffsetSeconds: Int) {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let d = calendar.date(from: components) else { return nil }
        self.date = d
    }
}

// MARK: - Wire model (decoded from the API response)

/// Top-level response from
/// `GET /v4/users/me/dataTypes/sleep/dataPoints`.
///
/// Shape verified against a real payload (2026-06). Decoding stays defensive —
/// unexpected/extra fields are ignored, and `mapped()` skips points it can't
/// normalize rather than throwing the whole batch away.
struct SleepDataPointsResponse: Decodable {
    let dataPoints: [SleepDataPoint]?
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case dataPoints
        case nextPageToken
    }

    /// Normalize to domain sessions, dropping anything incomplete, unparseable,
    /// or mirrored back from Apple HealthKit.
    func mapped() -> [SleepSession] {
        (dataPoints ?? []).compactMap { $0.asSession() }
    }
}

struct SleepDataPoint: Decodable {
    let name: String?
    let dataSource: WireDataSource?
    let sleep: WireSleepPayload?

    func asSession() -> SleepSession? {
        guard let id = dataPointID(fromName: name) else {
            Log.api.error("Skipping sleep dataPoint without a name")
            return nil
        }
        // Google mirrors Apple HealthKit data back through the Health API;
        // bridging those would re-import the user's own Apple samples.
        if dataSource?.isHealthKitMirror == true {
            Log.api.info("Skipping sleep dataPoint id=\(id) — HealthKit mirror, not Fitbit data")
            return nil
        }
        guard
            let interval = sleep?.interval,
            let start = interval.startDate,
            let end = interval.endDate,
            end > start
        else {
            Log.api.error("Skipping unparseable sleep dataPoint id=\(id)")
            return nil
        }

        let segments: [SleepStageSegment] = (sleep?.stages ?? []).compactMap { wire -> SleepStageSegment? in
            guard
                let s = wire.startTime.flatMap({ CivilTime(iso8601: $0)?.date }),
                let e = wire.endTime.flatMap({ CivilTime(iso8601: $0)?.date }),
                e > s
            else { return nil }
            let stage = SleepStage(wireValue: wire.stage ?? "")
            if stage == .unknown {
                Log.api.notice("Unknown sleep stage wire value: \(wire.stage ?? "nil")")
            }
            return SleepStageSegment(stage: stage, start: s, end: e)
        }

        guard !segments.isEmpty else {
            Log.api.notice("Sleep dataPoint id=\(id) had no usable stage segments")
            return nil
        }
        return SleepSession(id: id, start: start, end: end, stages: segments)
    }
}

/// The `"sleep"` payload object: session interval, `type` (`STAGES`/`CLASSIC`),
/// and per-stage segments. `summary`/`metadata` exist on the wire but are unused.
struct WireSleepPayload: Decodable {
    let interval: WireInterval?
    let type: String?
    let stages: [WireStageSegment]?
}

struct WireStageSegment: Decodable {
    let stage: String?
    let startTime: String?
    let endTime: String?

    enum CodingKeys: String, CodingKey {
        case stage = "type"
        case startTime = "startTime"
        case endTime = "endTime"
    }
}
