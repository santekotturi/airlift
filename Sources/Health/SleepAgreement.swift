import Foundation
import HealthKit

/// Pure computation behind the "Agreement with Apple Watch" meter: how often
/// the two trackers tell the same story, minute by minute.
///
/// Both sources are normalized onto one coarse scale (awake / core / deep /
/// REM / generic-asleep). For every minute where *both* sources claim a stage,
/// the minute counts as agreement when the stages match — with generic
/// "asleep" (classic Fitbit logs, Apple `asleepUnspecified`) matching any
/// sleep stage, since the trackers agree the user was asleep and only differ
/// in resolution. Apple `.inBed` is ignored: it overlaps real stages and says
/// nothing about sleep state.
enum SleepAgreement {
    enum Stage: Equatable {
        case awake, core, deep, rem, asleep

        init(_ stage: SleepStage) {
            switch stage {
            case .wake, .restless: self = .awake
            case .light: self = .core
            case .deep: self = .deep
            case .rem: self = .rem
            case .asleep, .unknown: self = .asleep
            }
        }

        init?(_ value: HKCategoryValueSleepAnalysis) {
            switch value {
            case .awake: self = .awake
            case .asleepCore: self = .core
            case .asleepDeep: self = .deep
            case .asleepREM: self = .rem
            case .asleepUnspecified: self = .asleep
            case .inBed: return nil
            @unknown default: return nil
            }
        }

        var isAsleep: Bool { self != .awake }

        /// Match = same stage, or both asleep with either side only knowing
        /// "asleep" generically.
        func agrees(with other: Stage) -> Bool {
            if self == other { return true }
            return isAsleep && other.isAsleep && (self == .asleep || other == .asleep)
        }
    }

    /// Agreement percent (0–100) across minutes covered by both sources, or
    /// nil when there is nothing to compare (no Apple data / no overlap).
    static func percent(
        google: [SleepStageSegment],
        apple: [AppleSleepSegment]
    ) -> Double? {
        let googleSpans = google.map { (Stage($0.stage), $0.start, $0.end) }
        let appleSpans = apple.compactMap { segment -> (Stage, Date, Date)? in
            guard let stage = Stage(segment.value) else { return nil }
            return (stage, segment.start, segment.end)
        }
        guard
            let start = (googleSpans.map(\.1) + appleSpans.map(\.1)).min(),
            let end = (googleSpans.map(\.2) + appleSpans.map(\.2)).max(),
            !googleSpans.isEmpty, !appleSpans.isEmpty
        else { return nil }

        var compared = 0
        var agreed = 0
        // Minute midpoints — cheap, exact enough for a meter, and immune to
        // boundary double-counting.
        var cursor = start.addingTimeInterval(30)
        while cursor < end {
            defer { cursor.addTimeInterval(60) }
            guard
                let g = stage(at: cursor, in: googleSpans),
                let a = stage(at: cursor, in: appleSpans)
            else { continue }
            compared += 1
            if g.agrees(with: a) { agreed += 1 }
        }
        guard compared > 0 else { return nil }
        return Double(agreed) / Double(compared) * 100
    }

    private static func stage(at instant: Date, in spans: [(Stage, Date, Date)]) -> Stage? {
        // Last matching span wins — later segments are corrections.
        spans.last { instant >= $0.1 && instant < $0.2 }?.0
    }
}
