import Foundation

/// How much human review stands between a fetch and a HealthKit write.
enum SyncMode: String, CaseIterable, Identifiable, Sendable {
    /// Items whose checks all pass land in Apple Health on their own;
    /// anything that draws a warning or failure waits in the review queue.
    case automatic
    /// Nothing is written without a tap (the original bring-up behavior).
    case reviewEverything

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .reviewEverything: return "Review everything"
        }
    }

    var blurb: String {
        switch self {
        case .automatic:
            return "Clean nights land in Apple Health on their own. Anything that fails a check waits for you."
        case .reviewEverything:
            return "Every night and metric waits for your OK before it's written."
        }
    }
}

/// Pure policy: what happens to a staged item with the given worst check
/// severity under the given mode. Kept free of I/O so the gate is testable
/// as a truth table.
enum SyncGate {
    enum Action: Equatable {
        case autoImport
        case review
    }

    static func action(for severity: CheckResult.Severity, mode: SyncMode) -> Action {
        switch mode {
        case .reviewEverything:
            return .review
        case .automatic:
            return severity == .pass || severity == .info ? .autoImport : .review
        }
    }

    /// Ledger status for an item the gate held back.
    static func heldStatus(for severity: CheckResult.Severity) -> DayStatus {
        severity == .warn || severity == .fail ? .quarantined : .pendingReview
    }
}

/// Persisted user choices that shape every sync pass.
protocol SyncSettingsStoring: Sendable {
    var syncMode: SyncMode { get set }
    /// Which quantity metrics sync at all (sleep is always on — it's the
    /// app's reason to exist). Lets Apple Watch owners turn off steps and
    /// distance, which double-count against iPhone/Watch sources.
    var enabledKinds: Set<MetricKind> { get set }
}

final class UserDefaultsSyncSettings: SyncSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let modeKey = "airlift.syncMode"
    private let kindsKey = "airlift.enabledKinds"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var syncMode: SyncMode {
        get {
            lock.withLock {
                (defaults.string(forKey: modeKey)).flatMap(SyncMode.init) ?? .automatic
            }
        }
        set {
            lock.withLock { defaults.set(newValue.rawValue, forKey: modeKey) }
        }
    }

    var enabledKinds: Set<MetricKind> {
        get {
            lock.withLock {
                guard let raw = defaults.array(forKey: kindsKey) as? [String] else {
                    return Set(MetricKind.allCases)
                }
                return Set(raw.compactMap(MetricKind.init))
            }
        }
        set {
            lock.withLock { defaults.set(newValue.map(\.rawValue).sorted(), forKey: kindsKey) }
        }
    }
}
