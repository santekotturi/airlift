import Foundation

/// Persists the high-water mark of synced data.
protocol SyncStateStoring: Sendable {
    var lastSyncedDate: Date? { get set }
}

final class UserDefaultsSyncState: SyncStateStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "airlift.lastSyncedDate") {
        self.defaults = defaults
        self.key = key
    }

    /// Timestamp of the last completed sync pass — drives the "Last checked"
    /// line on the home screen. The fetch *window* is derived per-kind from the
    /// ledger (see `SyncEngine.incrementalSince`), not from this value.
    var lastSyncedDate: Date? {
        get { lock.withLock { defaults.object(forKey: key) as? Date } }
        set { lock.withLock { defaults.set(newValue, forKey: key) } }
    }
}
