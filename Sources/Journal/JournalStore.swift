import Foundation
import Observation

/// Which night a tag belongs to, named by the day it ends on — the same key
/// sleep and every overnight metric already use, so a tag lines up with the
/// night's numbers without any translation.
enum JournalNight {
    /// "yyyy-MM-dd" of the wake day.
    static func key(_ wakeDay: Date) -> String { CivilDay.string(from: wakeDay) }

    /// The night about to be slept — or, in the small hours, the one still
    /// under way: taking melatonin at 1am belongs to the night that started
    /// yesterday evening, not to tomorrow's.
    static func tonight(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        guard calendar.component(.hour, from: now) >= smallHoursEnd else { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// Before this hour it's still last night.
    static let smallHoursEnd = 5

    /// "Tonight", "Last night", or "Monday night" (the evening it started).
    static func label(_ wakeDay: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: wakeDay)
        if day == tonight(now: now, calendar: calendar) { return "Tonight" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), day == tomorrow { return "Tonight" }
        if day == today { return "Last night" }
        let evening = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        return evening.formatted(.dateTime.weekday(.wide)) + " night"
    }
}

/// One thing logged against one night.
struct JournalEntry: Codable, Identifiable, Hashable {
    let id: UUID
    /// `JournalNight.key` of the night.
    var night: String
    /// Catalog or custom item ID.
    var itemID: String
    /// Snapshot of the item's name, so an entry still reads right if the
    /// catalog renames it.
    var name: String
    var category: TagCategory
    var amount: Double?
    var unit: String?
    /// When it happened, if the user set it — "magnesium at 21:30".
    var time: Date?
    var loggedAt: Date

    /// "Magnesium glycinate · 400 mg".
    var summary: String {
        guard let dose = doseText else { return name }
        return "\(name) · \(dose)"
    }

    var doseText: String? {
        guard let amount else { return nil }
        let number = amount.formatted(.number.precision(.fractionLength(0...2)))
        return unit.map { "\(number) \($0)" } ?? number
    }
}

/// The user's tags and notes, by night. Stored as one JSON file on the phone
/// — Apple Health has no type for "took magnesium", and this data never
/// leaves the device except through an explicit export.
@MainActor
@Observable
final class JournalStore {
    private struct Snapshot: Codable {
        var entries: [JournalEntry] = []
        var notes: [String: String] = [:]
        var customItems: [TagItem] = []
    }

    private(set) var entries: [JournalEntry] = []
    private(set) var notes: [String: String] = [:]
    private(set) var customItems: [TagItem] = []

    let catalog: TagCatalog
    private let url: URL?

    /// `url == nil` keeps everything in memory — tests and the UI mock.
    init(catalog: TagCatalog, url: URL? = JournalStore.defaultURL) {
        self.catalog = catalog
        self.url = url
        if let url,
           let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder.journal.decode(Snapshot.self, from: data) {
            entries = snapshot.entries
            notes = snapshot.notes
            customItems = snapshot.customItems
        }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Airlift", isDirectory: true)
            .appendingPathComponent("journal.json")
    }

    // MARK: - Reading

    /// Catalog plus the user's own items — what search runs over.
    var allItems: [TagItem] { customItems + catalog.items }

    func entries(night: String) -> [JournalEntry] {
        entries.filter { $0.night == night }.sorted { ($0.time ?? $0.loggedAt) < ($1.time ?? $1.loggedAt) }
    }

    func note(night: String) -> String { notes[night] ?? "" }

    /// Nights with anything logged, as keys.
    var taggedNights: Set<String> {
        Set(entries.map(\.night)).union(notes.filter { !$0.value.isEmpty }.keys)
    }

    /// How often each item has been logged — search boost and quick picks.
    var usage: [String: Int] {
        entries.reduce(into: [:]) { $0[$1.itemID, default: 0] += 1 }
    }

    /// The user's usual things, most-logged first (recency breaks ties).
    func frequentItems(limit: Int = 8) -> [TagItem] {
        let lastUsed = entries.reduce(into: [String: Date]()) { $0[$1.itemID] = max($0[$1.itemID] ?? .distantPast, $1.loggedAt) }
        let usage = usage
        let byID = Dictionary(allItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return usage.keys
            .sorted { (usage[$0] ?? 0, lastUsed[$0] ?? .distantPast) > (usage[$1] ?? 0, lastUsed[$1] ?? .distantPast) }
            .compactMap { byID[$0] }
            .prefix(limit)
            .map { $0 }
    }

    /// The dose last logged for an item, to prefill the next one.
    func lastDose(itemID: String) -> (amount: Double, unit: String?)? {
        entries.filter { $0.itemID == itemID }
            .sorted { $0.loggedAt > $1.loggedAt }
            .lazy
            .compactMap { entry in entry.amount.map { ($0, entry.unit) } }
            .first
    }

    // MARK: - Writing

    @discardableResult
    func add(_ item: TagItem, night: String, amount: Double? = nil, unit: String? = nil, time: Date? = nil, now: Date = Date()) -> JournalEntry {
        let entry = JournalEntry(
            id: UUID(), night: night, itemID: item.id, name: item.name, category: item.category,
            amount: amount, unit: unit, time: time, loggedAt: now
        )
        entries.append(entry)
        persist()
        return entry
    }

    func update(_ entry: JournalEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        persist()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func setNote(_ text: String, night: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[night] = trimmed.isEmpty ? nil : text
        persist()
    }

    /// Adds (or returns the existing) custom item with this name.
    func customItem(named name: String, category: TagCategory = .custom) -> TagItem {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = customItems.first(where: { TagSearch.normalize($0.name) == TagSearch.normalize(trimmed) }) {
            return existing
        }
        let item = TagItem(id: "custom-\(UUID().uuidString.lowercased())", name: trimmed, category: category)
        customItems.append(item)
        persist()
        return item
    }

    private func persist() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let snapshot = Snapshot(entries: entries, notes: notes, customItems: customItems)
            try JSONEncoder.journal.encode(snapshot).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            Log.sync.error("Journal persist failed: \(error.localizedDescription)")
        }
    }
}

private extension JSONEncoder {
    static var journal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var journal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
