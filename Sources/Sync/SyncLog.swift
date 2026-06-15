import Foundation
import Observation

/// One plain-language line in the "What crossed over" history.
struct SyncLogEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case fetched
        case imported
        case autoImported
        case tossed
        case held
        case nothingNew
        case connected
        case disconnected
        case error
    }

    let id: UUID
    let date: Date
    let kind: Kind
    /// Bold lead sentence ("Last night landed in Apple Health").
    let title: String
    /// Secondary plain-language detail ("7 h 24 m, 15 stage samples…").
    let detail: String
}

/// Newest-first, capped record of everything the bridge did — the History
/// screen renders this verbatim, so entries are written as user-facing
/// sentences, not log lines. Pass `defaults: nil` for an in-memory store
/// (UI-mock runs must not pollute the real history).
@MainActor
@Observable
final class SyncLogStore {
    private(set) var entries: [SyncLogEntry]

    private let defaults: UserDefaults?
    private let key: String
    private let cap: Int

    init(defaults: UserDefaults? = .standard, key: String = "airlift.syncLog", cap: Int = 200) {
        self.defaults = defaults
        self.key = key
        self.cap = cap
        if let data = defaults?.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SyncLogEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    func record(_ kind: SyncLogEntry.Kind, title: String, detail: String, date: Date = Date()) {
        entries.insert(SyncLogEntry(id: UUID(), date: date, kind: kind, title: title, detail: detail), at: 0)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
        persist()
    }

    #if DEBUG
    /// Replaces the whole log (UI-mock seeding), keeping newest-first order.
    func replaceAll(_ entries: [SyncLogEntry]) {
        self.entries = Array(entries.sorted { $0.date > $1.date }.prefix(cap))
        persist()
    }
    #endif

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    /// Count of entries of a kind — feeds the History stat tiles.
    func count(of kind: SyncLogEntry.Kind) -> Int {
        entries.filter { $0.kind == kind }.count
    }
}
