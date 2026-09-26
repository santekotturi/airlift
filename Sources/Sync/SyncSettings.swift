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
    /// Whether sleep sessions sync at all. Off by default since Google Health
    /// 5.05 (Aug 2026) writes sleep to Apple Health itself — syncing both
    /// double-counts every night. Toggleable for people not using that sync.
    var syncSleep: Bool { get set }
    /// Which quantity metrics sync at all. Defaults to HRV only: it's the one
    /// metric Google Health's own Apple Health sync refuses to write (RMSSD vs
    /// SDNN), so it's the one bridge still worth running. Everything else is
    /// opt-in for people not using Google Health's sync.
    var enabledKinds: Set<MetricKind> { get set }
    /// Best device label detected from wire `dataSource.device` blocks.
    var detectedDeviceLabel: String? { get set }
    /// User-chosen device name; wins over detection everywhere.
    var deviceNameOverride: String? { get set }
}

final class UserDefaultsSyncSettings: SyncSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let modeKey = "airlift.syncMode"
    private let syncSleepKey = "airlift.syncSleep"
    private let kindsKey = "airlift.enabledKinds"
    private let detectedDeviceKey = "airlift.detectedDeviceLabel"
    private let deviceOverrideKey = "airlift.deviceNameOverride"
    private let hrvOnlyMigrationKey = "airlift.hrvOnlyMigration"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateToHRVOnly()
    }

    /// One-time reset to the HRV-only defaults, applied to installs that
    /// predate Google Health 5.05's own Apple Health sync (which covers
    /// everything Airlift bridged except HRV). Runs once; the Settings
    /// toggles still re-enable anything afterwards.
    private func migrateToHRVOnly() {
        lock.withLock {
            guard !defaults.bool(forKey: hrvOnlyMigrationKey) else { return }
            defaults.set(true, forKey: hrvOnlyMigrationKey)
            // Only installs that had already persisted choices need resetting;
            // fresh installs just fall through to the new defaults.
            if defaults.object(forKey: syncSleepKey) != nil {
                defaults.set(false, forKey: syncSleepKey)
            }
            if defaults.object(forKey: kindsKey) != nil {
                defaults.set([MetricKind.heartRateVariability.rawValue], forKey: kindsKey)
            }
        }
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

    var syncSleep: Bool {
        // Defaults to false when never set — Google Health writes sleep itself.
        get { lock.withLock { defaults.object(forKey: syncSleepKey) as? Bool ?? false } }
        set { lock.withLock { defaults.set(newValue, forKey: syncSleepKey) } }
    }

    var enabledKinds: Set<MetricKind> {
        get {
            lock.withLock {
                guard let raw = defaults.array(forKey: kindsKey) as? [String] else {
                    return [.heartRateVariability]
                }
                return Set(raw.compactMap(MetricKind.init))
            }
        }
        set {
            lock.withLock { defaults.set(newValue.map(\.rawValue).sorted(), forKey: kindsKey) }
        }
    }

    var detectedDeviceLabel: String? {
        get { lock.withLock { defaults.string(forKey: detectedDeviceKey) } }
        set { lock.withLock { defaults.set(newValue, forKey: detectedDeviceKey) } }
    }

    var deviceNameOverride: String? {
        get { lock.withLock { defaults.string(forKey: deviceOverrideKey) } }
        set { lock.withLock { defaults.set(newValue, forKey: deviceOverrideKey) } }
    }
}
