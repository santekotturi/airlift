import XCTest
@testable import AirKit

@MainActor
final class SyncLogTests: XCTestCase {
    func testRecordInsertsNewestFirst() {
        let store = SyncLogStore(defaults: nil)
        store.record(.fetched, title: "first", detail: "")
        store.record(.imported, title: "second", detail: "")
        XCTAssertEqual(store.entries.map(\.title), ["second", "first"])
    }

    func testCapDropsOldest() {
        let store = SyncLogStore(defaults: nil, cap: 3)
        for i in 1...5 {
            store.record(.fetched, title: "\(i)", detail: "")
        }
        XCTAssertEqual(store.entries.map(\.title), ["5", "4", "3"])
    }

    func testCountByKind() {
        let store = SyncLogStore(defaults: nil)
        store.record(.imported, title: "a", detail: "")
        store.record(.autoImported, title: "b", detail: "")
        store.record(.imported, title: "c", detail: "")
        XCTAssertEqual(store.count(of: .imported), 2)
        XCTAssertEqual(store.count(of: .autoImported), 1)
        XCTAssertEqual(store.count(of: .tossed), 0)
    }

    func testPersistsAcrossInstances() {
        let suiteName = "synclog-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SyncLogStore(defaults: defaults).record(.connected, title: "hello", detail: "world")
        let reloaded = SyncLogStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries.first?.title, "hello")
        XCTAssertEqual(reloaded.entries.first?.kind, .connected)
    }

    func testInMemoryStoreDoesNotPersist() {
        let suiteName = "synclog-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SyncLogStore(defaults: nil)
        store.record(.fetched, title: "ephemeral", detail: "")
        XCTAssertNil(defaults.data(forKey: "airkit.syncLog"))
    }

    #if DEBUG
    func testReplaceAllSortsNewestFirstAndCaps() {
        let store = SyncLogStore(defaults: nil, cap: 2)
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let newest = Date(timeIntervalSince1970: 3_000)
        store.replaceAll([
            SyncLogEntry(id: UUID(), date: old, kind: .fetched, title: "old", detail: ""),
            SyncLogEntry(id: UUID(), date: newest, kind: .fetched, title: "newest", detail: ""),
            SyncLogEntry(id: UUID(), date: new, kind: .fetched, title: "new", detail: ""),
        ])
        XCTAssertEqual(store.entries.map(\.title), ["newest", "new"])
    }
    #endif
}
