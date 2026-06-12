import Foundation

/// How much human review stands between a fetch and a HealthKit write.
enum SyncMode: String, CaseIterable, Identifiable, Sendable {
    /// Stage everything; the user imports each item by hand (bring-up mode).
    case reviewAll
    /// Auto-import items whose sanity checks pass; hold warns and fails.
    case automatic
    /// Auto-import everything except outright check failures.
    case fullyAutomatic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reviewAll: return "Review everything"
        case .automatic: return "Automatic (checked)"
        case .fullyAutomatic: return "Fully automatic"
        }
    }

    var footnote: String {
        switch self {
        case .reviewAll:
            return "Nothing is written to Apple Health until you import it."
        case .automatic:
            return "Data that passes every sanity check imports on its own; anything flagged waits for your review."
        case .fullyAutomatic:
            return "Everything imports except outright check failures."
        }
    }
}

/// Pure policy: what happens to a staged item with the given worst check
/// severity under the given mode. Kept free of I/O so the gate is testable
/// as a 3×4 truth table.
enum SyncGate {
    enum Action: Equatable {
        case autoImport
        case review
    }

    static func action(for severity: CheckResult.Severity, mode: SyncMode) -> Action {
        switch mode {
        case .reviewAll:
            return .review
        case .automatic:
            return severity == .pass || severity == .info ? .autoImport : .review
        case .fullyAutomatic:
            return severity == .fail ? .review : .autoImport
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
    private let modeKey = "airkit.syncMode"
    private let kindsKey = "airkit.enabledKinds"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var syncMode: SyncMode {
        get {
            lock.withLock {
                (defaults.string(forKey: modeKey)).flatMap(SyncMode.init) ?? .reviewAll
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
