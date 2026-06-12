import Foundation

/// Sync outcome of one (data kind, civil day) cell.
///
/// The ledger replaces the single `lastSyncedDate` high-water mark as the
/// user-facing answer to "is Tuesday's sleep in Apple Health?" — one entry per
/// data kind per civil day, persisted across launches, updated by every sync
/// pass and by review actions (import / toss).
enum DayStatus: Equatable, Codable {
    /// Samples written to HealthKit. Counts accumulate when a re-pull lands
    /// more data on a day that already synced.
    case synced(samples: Int, at: Date)
    /// Staged and waiting on the user (review-everything mode).
    case pendingReview
    /// A sanity check warned or failed — held for the user to inspect.
    case quarantined
    /// A sync covered this day and Google returned nothing for it.
    case noData
    /// The user discarded this day's data; tossed IDs never re-stage.
    case tossed
}

struct LedgerEntry: Equatable, Codable, Identifiable {
    /// `"sleep"` or a `MetricKind` raw value.
    let kind: String
    /// Civil day `"yyyy-MM-dd"` — stored as a string so a cell can't drift to
    /// a different day if the phone's timezone changes after the fact.
    let day: String
    var status: DayStatus

    var id: String { "\(kind)|\(day)" }
}

/// Ledger kind key for sleep sessions (metrics use `MetricKind.rawValue`).
let sleepLedgerKind = "sleep"

protocol SyncLedgerStoring: Sendable {
    func status(kind: String, day: String) -> DayStatus?
    func set(_ status: DayStatus, kind: String, day: String)
    var all: [LedgerEntry] { get }
}

extension SyncLedgerStoring {
    /// Marks samples written, accumulating counts across re-pulls of one day.
    func recordSynced(kind: String, day: String, samples: Int, at date: Date) {
        if case .synced(let existing, _)? = status(kind: kind, day: day) {
            set(.synced(samples: existing + samples, at: date), kind: kind, day: day)
        } else {
            set(.synced(samples: samples, at: date), kind: kind, day: day)
        }
    }

    /// Fills a cell only when nothing is known about it yet — a `.noData`
    /// sweep must never downgrade a synced/held/tossed cell.
    func fillIfEmpty(_ status: DayStatus, kind: String, day: String) {
        guard self.status(kind: kind, day: day) == nil else { return }
        set(status, kind: kind, day: day)
    }
}

/// Civil-day string helpers shared by the ledger and its writers.
enum CivilDay {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// Inverse of `string(from:)` — start of the civil day, current timezone.
    static func date(from string: String) -> Date? {
        formatter.date(from: string).map { Calendar.current.startOfDay(for: $0) }
    }

    /// Every civil day from `since` through `through`, inclusive, oldest first.
    static func days(
        from since: Date,
        through end: Date,
        calendar: Calendar = .current
    ) -> [String] {
        var days: [String] = []
        var cursor = calendar.startOfDay(for: since)
        let last = calendar.startOfDay(for: end)
        while cursor <= last {
            days.append(string(from: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }
}

/// JSON-file-backed ledger (Application Support). The whole ledger is a small
/// dictionary — ~8 kinds × a few weeks of days — so load-once + atomic
/// rewrite-on-change is plenty.
final class FileSyncLedger: SyncLedgerStoring, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var entries: [String: LedgerEntry]

    init(url: URL? = nil) {
        let resolved = url ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Airlift", isDirectory: true)
            .appendingPathComponent("ledger.json")
        self.url = resolved
        if let data = try? Data(contentsOf: resolved),
           let decoded = try? JSONDecoder().decode([String: LedgerEntry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    var all: [LedgerEntry] {
        lock.withLock { Array(entries.values) }
    }

    func status(kind: String, day: String) -> DayStatus? {
        lock.withLock { entries["\(kind)|\(day)"]?.status }
    }

    func set(_ status: DayStatus, kind: String, day: String) {
        lock.withLock {
            entries["\(kind)|\(day)"] = LedgerEntry(kind: kind, day: day, status: status)
            persist()
        }
    }

    /// Caller must hold `lock`.
    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.sync.error("Ledger persist failed: \(error.localizedDescription)")
        }
    }
}

/// Non-persisting ledger — UI-mock runs and tests.
final class InMemorySyncLedger: SyncLedgerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: LedgerEntry] = [:]

    init() {}

    var all: [LedgerEntry] {
        lock.withLock { Array(entries.values) }
    }

    func status(kind: String, day: String) -> DayStatus? {
        lock.withLock { entries["\(kind)|\(day)"]?.status }
    }

    func set(_ status: DayStatus, kind: String, day: String) {
        lock.withLock { entries["\(kind)|\(day)"] = LedgerEntry(kind: kind, day: day, status: status) }
    }
}
