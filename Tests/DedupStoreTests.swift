import XCTest
@testable import AirKit

final class DedupStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: UserDefaultsDedupStore!

    override func setUp() {
        super.setUp()
        // Isolated suite so tests don't touch real app state.
        let suite = "airkit.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = UserDefaultsDedupStore(defaults: defaults, key: "synced")
    }

    func testInsertAndContains() {
        XCTAssertFalse(store.contains("dp-1"))
        store.insert("dp-1")
        XCTAssertTrue(store.contains("dp-1"))
    }

    func testInsertIsIdempotent() {
        store.insert("dp-1")
        store.insert("dp-1")
        XCTAssertEqual(store.all, ["dp-1"])
    }

    func testInsertAllBatches() {
        store.insertAll(["a", "b", "c"])
        XCTAssertEqual(store.all, ["a", "b", "c"])
        store.insertAll(["b", "d"])
        XCTAssertEqual(store.all, ["a", "b", "c", "d"])
        store.insertAll([])
        XCTAssertEqual(store.all, ["a", "b", "c", "d"])
    }

    func testRemove() {
        store.insert("dp-1")
        store.insert("dp-2")
        store.remove("dp-1")
        XCTAssertFalse(store.contains("dp-1"))
        XCTAssertTrue(store.contains("dp-2"))
    }

    func testPersistsAcrossInstances() {
        store.insert("dp-42")
        let reopened = UserDefaultsDedupStore(defaults: defaults, key: "synced")
        XCTAssertTrue(reopened.contains("dp-42"))
    }
}
