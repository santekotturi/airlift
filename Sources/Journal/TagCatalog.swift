import Foundation

/// What a tag is about — drives the symbol and the browse sections.
enum TagCategory: String, Codable, CaseIterable, Identifiable {
    case supplement, medication, substance, food, exercise, light, temperature
    case environment, mindBody, device, recovery, schedule, health, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .supplement: "Supplements"
        case .medication: "Medications"
        case .substance: "Caffeine, alcohol & more"
        case .food: "Food & drink"
        case .exercise: "Exercise"
        case .light: "Light"
        case .temperature: "Heat & cold"
        case .environment: "Sleep environment"
        case .mindBody: "Mind & body"
        case .device: "Devices & gear"
        case .recovery: "Recovery"
        case .schedule: "Schedule & travel"
        case .health: "Health & life"
        case .custom: "Your own"
        }
    }

    var symbol: String {
        switch self {
        case .supplement: "pills.fill"
        case .medication: "cross.case.fill"
        case .substance: "cup.and.saucer.fill"
        case .food: "fork.knife"
        case .exercise: "figure.run"
        case .light: "sun.max.fill"
        case .temperature: "thermometer.medium"
        case .environment: "bed.double.fill"
        case .mindBody: "brain.head.profile"
        case .device: "applewatch"
        case .recovery: "hands.sparkles.fill"
        case .schedule: "clock.fill"
        case .health: "heart.text.square.fill"
        case .custom: "tag.fill"
        }
    }
}

/// One thing a night can be tagged with: a supplement, a sauna session, a
/// late dinner. Catalog items ship in `TagCatalog.json`; custom ones are the
/// user's own and live in the journal store.
struct TagItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: TagCategory
    var aliases: [String] = []
    /// Units a dose could be logged in; empty when a dose makes no sense.
    var units: [String] = []
}

/// The bundled inventory, searched as the user types.
struct TagCatalog {
    let items: [TagItem]

    private struct File: Decodable {
        let version: Int
        let items: [TagItem]
    }

    static let empty = TagCatalog(items: [])

    /// Loads `TagCatalog.json` from `bundle`. A missing or malformed file is a
    /// build problem, not a user one — it yields an empty catalog (custom tags
    /// still work) rather than a crash.
    static func load(bundle: Bundle = .main) -> TagCatalog {
        guard
            let url = bundle.url(forResource: "TagCatalog", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            Log.sync.error("TagCatalog.json missing from the bundle")
            return .empty
        }
        do {
            return TagCatalog(items: try JSONDecoder().decode(File.self, from: data).items)
        } catch {
            Log.sync.error("TagCatalog.json failed to decode: \(error.localizedDescription)")
            return .empty
        }
    }
}

/// Type-ahead search over catalog and custom items.
///
/// Every word typed must match the start of some word in the item's name or
/// one of its aliases ("mag gly" finds magnesium glycinate). Exact and prefix
/// matches on the whole name rank first, then word-prefix, then substring;
/// items the user has logged before get a boost so their usual things come up
/// first. When nothing matches, a one-typo tolerance kicks in for queries long
/// enough that a single edit is plausibly a slip ("ashwaganda", "melatonim").
enum TagSearch {
    static func results(
        _ query: String,
        in items: [TagItem],
        usage: [String: Int] = [:],
        limit: Int = 40
    ) -> [TagItem] {
        let tokens = normalize(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let joined = tokens.joined(separator: " ")

        var scored: [(item: TagItem, score: Double)] = []
        for item in items {
            let names = [normalize(item.name)] + item.aliases.map(normalize)
            guard let score = score(tokens: tokens, joined: joined, names: names) else { continue }
            scored.append((item, score + boost(usage[item.id])))
        }
        if scored.isEmpty, joined.count >= 5 {
            for item in items {
                let names = [normalize(item.name)] + item.aliases.map(normalize)
                if names.contains(where: { fuzzyMatches(tokens: tokens, name: $0) }) {
                    scored.append((item, 10 + boost(usage[item.id])))
                }
            }
        }
        return scored
            .sorted { ($0.score, -$0.item.name.count) > ($1.score, -$1.item.name.count) }
            .prefix(limit)
            .map(\.item)
    }

    /// Lowercased, accents and punctuation folded to spaces — "L-Theanine"
    /// and "l theanine" are the same query.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let spaced = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(spaced).split(separator: " ").joined(separator: " ")
    }

    private static func score(tokens: [String], joined: String, names: [String]) -> Double? {
        var best: Double?
        for (index, name) in names.enumerated() {
            let isAlias = index > 0
            var score: Double?
            if name == joined {
                score = isAlias ? 95 : 100
            } else if name.hasPrefix(joined) {
                score = isAlias ? 75 : 85
            } else {
                let words = name.split(separator: " ")
                if tokens.allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) {
                    score = isAlias ? 55 : 65
                } else if name.contains(joined) {
                    score = isAlias ? 30 : 40
                }
            }
            if let score { best = max(best ?? 0, score) }
        }
        return best
    }

    /// Logged before → up to +20, growing slowly with use.
    private static func boost(_ count: Int?) -> Double {
        guard let count, count > 0 else { return 0 }
        return min(20, 8 + log2(Double(count)) * 4)
    }

    /// Each token within one edit of the start of some word.
    private static func fuzzyMatches(tokens: [String], name: String) -> Bool {
        let words = name.split(separator: " ").map(String.init)
        return tokens.allSatisfy { token in
            guard token.count >= 4 else { return words.contains { $0.hasPrefix(token) } }
            return words.contains { word in
                let prefix = String(word.prefix(token.count))
                return editDistance(token, prefix, limit: 1) <= 1
                    || editDistance(token, word, limit: 1) <= 1
            }
        }
    }

    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}
