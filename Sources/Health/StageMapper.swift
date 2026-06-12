import Foundation
import HealthKit

/// Maps Fitbit/Google sleep stages to HealthKit's sleep-analysis values.
///
/// This is the heart of the bridge and is kept pure (no HealthKit I/O) so it can
/// be unit-tested exhaustively. Mapping per PRD §7:
///
///   wake     → .awake
///   light    → .asleepCore
///   deep     → .asleepDeep
///   rem      → .asleepREM
///   asleep   → .asleepUnspecified   (classic, non-staged logs)
///   restless → .awake               (classic logs)
///   unknown  → .asleepUnspecified   (schema-drift fallback, PRD §9)
enum StageMapper {
    static func healthKitValue(for stage: SleepStage) -> HKCategoryValueSleepAnalysis {
        switch stage {
        case .wake: return .awake
        case .light: return .asleepCore
        case .deep: return .asleepDeep
        case .rem: return .asleepREM
        case .asleep: return .asleepUnspecified
        case .restless: return .awake
        case .unknown: return .asleepUnspecified
        }
    }
}
