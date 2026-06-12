import Foundation

/// Persists the high-water mark of synced data.
protocol SyncStateStoring: Sendable {
    var lastSyncedDate: Date? { get set }
}

final class UserDefaultsSyncState: SyncStateStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "airkit.lastSyncedDate") {
        self.defaults = defaults
        self.key = key
    }

    var lastSyncedDate: Date? {
        get { lock.withLock { defaults.object(forKey: key) as? Date } }
        set { lock.withLock { defaults.set(newValue, forKey: key) } }
    }
}

/// Pure computation of the fetch window — kept separate from I/O so it can be
/// unit-tested directly (PRD §8).
enum SyncWindow {
    /// The civil date from which to fetch sleep.
    ///
    /// - First run (`lastSynced == nil`): look back `firstRunLookbackDays`.
    /// - Otherwise: re-pull the last `rePullDays` days as well, because sleep is
    ///   finalized only after wake + device sync and sessions may arrive late or
    ///   be edited upstream. So we fetch since `min(lastSynced, now - rePullDays)`.
    static func fetchSince(
        lastSynced: Date?,
        now: Date,
        firstRunLookbackDays: Int = 7,
        rePullDays: Int = 2
    ) -> Date {
        let rePullFloor = now.addingTimeInterval(-Double(rePullDays) * 86_400)
        guard let lastSynced else {
            return now.addingTimeInterval(-Double(firstRunLookbackDays) * 86_400)
        }
        return min(lastSynced, rePullFloor)
    }
}
