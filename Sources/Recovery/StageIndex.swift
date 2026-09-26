import Foundation
import HealthKit

/// Which part of the night a recovery metric is measured over.
///
/// The hypothesis this exists to test: recovery is best read from deep sleep,
/// so restricting to it should sharpen the signal. The practical target is
/// core+deep rather than deep alone, because Apple Watch is widely reported to
/// score true deep sleep as core — and because deep-only leaves so few samples
/// a night that nothing can be concluded from them.
enum StageSelection: String, CaseIterable, Identifiable {
    case allSleep
    case coreAndDeep
    case deepOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allSleep: "All sleep"
        case .coreAndDeep: "Core + deep"
        case .deepOnly: "Deep only"
        }
    }

    var detail: String {
        switch self {
        case .allSleep: "Every scored asleep minute, REM included."
        case .coreAndDeep: "NREM. The target zone — and the one Apple's core/deep confusion stays inside of."
        case .deepOnly: "Apple scores little of the night as deep, so expect too few samples to conclude from."
        }
    }

    /// `.asleep` — Apple's `asleepUnspecified`, Fitbit's classic unstaged logs —
    /// is excluded from every restricted selection. It means "asleep, stage
    /// unknown", so counting it as NREM would quietly fill the target zone with
    /// minutes that might be REM.
    func includes(_ stage: SleepAgreement.Stage) -> Bool {
        switch self {
        case .allSleep: return stage.isAsleep
        case .coreAndDeep: return stage == .core || stage == .deep
        case .deepOnly: return stage == .deep
        }
    }
}

/// Which hypnogram labels the samples.
///
/// The interesting one is `.fitbit`: Airlift lands Fitbit's stages in HealthKit
/// beside Apple's, so Apple's own HRV and heart-rate samples can be labelled
/// with Fitbit's scoring. If restricting to core+deep sharpens agreement under
/// Fitbit's hypnogram but not Apple's, the staging — not the sensor — is what
/// was blurring the signal.
enum StagingSource: String, CaseIterable, Identifiable {
    case apple
    case fitbit
    case bothAgree

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .fitbit: "Fitbit"
        case .bothAgree: "Both agree"
        }
    }

    var detail: String {
        switch self {
        case .apple: "Apple Watch's own scoring."
        case .fitbit: "Airlifted Fitbit stages, applied to Apple's samples."
        case .bothAgree: "Only minutes where the two hypnograms match — strictest, and the smallest sample."
        }
    }
}

/// A night's hypnogram as a minute grid, so any sample can be asked what stage
/// it fell in.
///
/// A minute grid rather than interval search because it makes the two
/// operations that matter cheap and exact: labelling thousands of heart-rate
/// samples, and intersecting two sources' scoring minute by minute. It matches
/// the resolution both devices actually score at, and `SleepAgreement` already
/// compares them on the same grid.
struct StageIndex: Equatable {
    typealias Stage = SleepAgreement.Stage

    /// Minutes since the epoch → the stage covering that minute.
    private let minutes: [Int: Stage]

    static let empty = StageIndex(minutes: [:])

    private init(minutes: [Int: Stage]) {
        self.minutes = minutes
    }

    /// Later segments overwrite earlier ones on the minutes they share — the
    /// same "corrections win" rule `SleepAgreement` uses. Apple in particular
    /// emits overlapping segments where a later one revises an earlier call.
    init(spans: [(stage: Stage, start: Date, end: Date)]) {
        var grid: [Int: Stage] = [:]
        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.end > span.start else { continue }
            // Minute *midpoints*, matching SleepAgreement — a boundary at
            // 03:00 then belongs to exactly one of the two segments touching it.
            var cursor = Self.minuteIndex(span.start.addingTimeInterval(30))
            let last = Self.minuteIndex(span.end.addingTimeInterval(-30))
            while cursor <= last {
                grid[cursor] = span.stage
                cursor += 1
            }
        }
        self.minutes = grid
    }

    /// Apple Watch (or any non-Airlift source) sleep segments.
    init(apple segments: [AppleSleepSegment]) {
        self.init(spans: segments.compactMap { segment in
            Stage(segment.value).map { (stage: $0, start: segment.start, end: segment.end) }
        })
    }

    /// Airlift-authored sleep samples — Fitbit's hypnogram, read back out of
    /// HealthKit where it was imported.
    init(airlifted samples: [HealthKitReader.OwnSample]) {
        self.init(spans: samples.compactMap { sample in
            guard
                let value = HKCategoryValueSleepAnalysis(rawValue: Int(sample.value)),
                let stage = Stage(value)
            else { return nil }
            return (stage: stage, start: sample.start, end: sample.end)
        })
    }

    /// Minutes where both hypnograms agree, keeping the agreed stage.
    ///
    /// Uses `Stage.agrees(with:)`, so a source that only knows "asleep" matches
    /// a staged sleep minute — but the *specific* stage is then the one that
    /// has one, since an unstaged minute cannot restrict anything.
    static func intersection(_ first: StageIndex, _ second: StageIndex) -> StageIndex {
        var grid: [Int: Stage] = [:]
        for (minute, stage) in first.minutes {
            guard let other = second.minutes[minute], stage.agrees(with: other) else { continue }
            grid[minute] = stage == .asleep ? other : stage
        }
        return StageIndex(minutes: grid)
    }

    func stage(at instant: Date) -> Stage? {
        minutes[Self.minuteIndex(instant)]
    }

    /// True when the instant falls in a minute the selection covers. Samples in
    /// unscored minutes are excluded rather than assumed asleep.
    func includes(_ instant: Date, in selection: StageSelection) -> Bool {
        guard let stage = stage(at: instant) else { return false }
        return selection.includes(stage)
    }

    /// How much of the night the selection actually covers. The honest
    /// denominator for "4 samples in the target zone" — 4 samples over 20
    /// minutes of deep sleep is a different claim than 4 over 5 hours.
    func minuteCount(in selection: StageSelection) -> Int {
        minutes.values.filter { selection.includes($0) }.count
    }

    var scoredMinuteCount: Int { minutes.count }

    var isEmpty: Bool { minutes.isEmpty }

    /// Contiguous runs of one stage — the shape the hypnogram chart draws, and
    /// what bout structure is counted from.
    func bouts(of stage: Stage) -> [DateInterval] {
        let indices = minutes.filter { $0.value == stage }.keys.sorted()
        var bouts: [DateInterval] = []
        var runStart: Int?
        var previous: Int?
        for index in indices {
            if runStart == nil { runStart = index }
            if let last = previous, index != last + 1 {
                bouts.append(Self.interval(from: runStart ?? last, through: last))
                runStart = index
            }
            previous = index
        }
        if let start = runStart, let last = previous {
            bouts.append(Self.interval(from: start, through: last))
        }
        return bouts
    }

    /// Every scored run in time order, for drawing the hypnogram.
    func runs() -> [(stage: Stage, interval: DateInterval)] {
        let sorted = minutes.keys.sorted()
        var runs: [(Stage, DateInterval)] = []
        var runStart: Int?
        var previous: Int?
        var currentStage: Stage?
        for index in sorted {
            let stage = minutes[index]
            if runStart == nil {
                runStart = index
                currentStage = stage
            } else if let last = previous, index != last + 1 || stage != currentStage {
                if let start = runStart, let held = currentStage {
                    runs.append((held, Self.interval(from: start, through: last)))
                }
                runStart = index
                currentStage = stage
            }
            previous = index
        }
        if let start = runStart, let last = previous, let held = currentStage {
            runs.append((held, Self.interval(from: start, through: last)))
        }
        return runs.map { (stage: $0.0, interval: $0.1) }
    }

    // MARK: - Grid

    private static func minuteIndex(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    private static func interval(from first: Int, through last: Int) -> DateInterval {
        DateInterval(
            start: Date(timeIntervalSince1970: Double(first) * 60),
            end: Date(timeIntervalSince1970: Double(last + 1) * 60)
        )
    }
}
