import XCTest
@testable import Airlift

@MainActor
final class JournalTests: XCTestCase {
    private let items = [
        TagItem(id: "magnesium-glycinate", name: "Magnesium glycinate", category: .supplement,
                aliases: ["mag glycinate", "magnesium bisglycinate"], units: ["mg"]),
        TagItem(id: "magnesium-citrate", name: "Magnesium citrate", category: .supplement, aliases: [], units: ["mg"]),
        TagItem(id: "ashwagandha", name: "Ashwagandha", category: .supplement, aliases: ["ksm-66"], units: ["mg"]),
        TagItem(id: "sauna", name: "Sauna", category: .temperature, aliases: [], units: ["min"]),
        TagItem(id: "l-theanine", name: "L-Theanine", category: .supplement, aliases: [], units: ["mg"]),
    ]

    // MARK: - Search

    func testEveryWordMatchesAWordStart() {
        XCTAssertEqual(TagSearch.results("mag gly", in: items).map(\.id), ["magnesium-glycinate"])
    }

    func testAliasFindsItem() {
        XCTAssertEqual(TagSearch.results("ksm", in: items).first?.id, "ashwagandha")
    }

    func testPunctuationIsIgnored() {
        XCTAssertEqual(TagSearch.results("l theanine", in: items).first?.id, "l-theanine")
    }

    func testOneTypoIsForgivenOnLongQueries() {
        XCTAssertEqual(TagSearch.results("ashwaganda", in: items).first?.id, "ashwagandha")
        XCTAssertTrue(TagSearch.results("xyzq", in: items).isEmpty)
    }

    func testUsedItemsRankFirst() {
        let plain = TagSearch.results("magnesium", in: items)
        let used = TagSearch.results("magnesium", in: items, usage: ["magnesium-citrate": 5])
        XCTAssertEqual(plain.count, 2)
        XCTAssertEqual(used.first?.id, "magnesium-citrate")
    }

    func testBundledCatalogLoadsAndIsUnique() {
        let catalog = TagCatalog.load()
        XCTAssertGreaterThan(catalog.items.count, 500)
        XCTAssertEqual(Set(catalog.items.map(\.id)).count, catalog.items.count)
        XCTAssertEqual(TagSearch.results("mag glycinate", in: catalog.items).first?.id, "magnesium-glycinate")
    }

    // MARK: - Nights

    private func date(_ day: Int, _ hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    func testCurrentNightSwitchesAtNoon() {
        XCTAssertEqual(JournalNight.key(JournalNight.current(now: date(30, 7))), "2026-09-30")
        XCTAssertEqual(JournalNight.key(JournalNight.current(now: date(30, 22))), "2026-10-01")
    }

    func testLabels() {
        let now = date(30, 20)
        XCTAssertEqual(JournalNight.label(date(1 + 30, 0), now: now), "Tonight")
        XCTAssertEqual(JournalNight.label(date(30, 0), now: now), "Last night")
        XCTAssertEqual(JournalNight.label(date(29, 0), now: now), "Monday night")
    }

    // MARK: - Store

    func testStorePersistsAndPrefillsLastDose() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JournalStore(catalog: TagCatalog(items: items), url: url)
        store.add(items[0], night: "2026-09-29", amount: 300, unit: "mg", now: date(28, 21))
        store.add(items[0], night: "2026-09-30", amount: 400, unit: "mg", now: date(29, 21))
        store.setNote("Woke at 3", night: "2026-09-30")
        let custom = store.customItem(named: "Late espresso")
        XCTAssertEqual(store.customItem(named: "late  espresso").id, custom.id)

        let reopened = JournalStore(catalog: TagCatalog(items: items), url: url)
        XCTAssertEqual(reopened.entries(night: "2026-09-30").map(\.summary), ["Magnesium glycinate · 400 mg"])
        XCTAssertEqual(reopened.note(night: "2026-09-30"), "Woke at 3")
        XCTAssertEqual(reopened.lastDose(itemID: "magnesium-glycinate")?.amount, 400)
        XCTAssertEqual(reopened.frequentItems().first?.id, "magnesium-glycinate")
        XCTAssertTrue(reopened.allItems.contains { $0.name == "Late espresso" })
    }

    // MARK: - Export

    func testCSVHasOneColumnPerItemAndOneRowPerNight() {
        let store = JournalStore(catalog: TagCatalog(items: items), url: nil)
        store.add(items[0], night: "2026-09-29", amount: 400, unit: "mg")
        store.add(items[3], night: "2026-09-30")
        store.setNote("hot room, woke twice", night: "2026-09-30")
        let csv = JournalExport.csv(entries: store.entries, notes: store.notes, sleep: .empty)
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("Magnesium glycinate (mg),Sauna"))
        XCTAssertTrue(lines[1].hasPrefix("2026-09-29,,"))
        XCTAssertTrue(lines[1].hasSuffix(",400,"))
        XCTAssertTrue(lines[2].contains("\"hot room, woke twice\""))
        XCTAssertTrue(lines[2].hasSuffix(",,1"))
    }
}
