import Foundation

/// Tracks which Google sleep dataPoint IDs have already been written to HealthKit.
///
/// HealthKit has no native upsert, so this set is the source of truth for
/// "already written" (PRD §8). Backed by `UserDefaults` here for simplicity; the
/// protocol leaves room to swap in SQLite if the set ever grows large.
protocol DedupStoring: Sendable {
    func contains(_ id: String) -> Bool
    func insert(_ id: String)
    /// Batch insert — one persistence write for the whole set. Metric batches
    /// can carry thousands of IDs per day.
    func insertAll(_ ids: [String])
    func remove(_ id: String)
    var all: Set<String> { get }
}

final class UserDefaultsDedupStore: DedupStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "airkit.syncedDataPointIDs") {
        self.defaults = defaults
        self.key = key
    }

    var all: Set<String> {
        lock.withLock {
            let array = defaults.array(forKey: key) as? [String] ?? []
            return Set(array)
        }
    }

    func contains(_ id: String) -> Bool {
        lock.withLock {
            let array = defaults.array(forKey: key) as? [String] ?? []
            return array.contains(id)
        }
    }

    func insert(_ id: String) {
        insertAll([id])
    }

    func insertAll(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            var set = Set(defaults.array(forKey: key) as? [String] ?? [])
            set.formUnion(ids)
            defaults.set(Array(set), forKey: key)
        }
    }

    func remove(_ id: String) {
        lock.withLock {
            var set = Set(defaults.array(forKey: key) as? [String] ?? [])
            set.remove(id)
            defaults.set(Array(set), forKey: key)
        }
    }
}
