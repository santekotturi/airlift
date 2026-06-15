import XCTest
@testable import Airlift

final class SessionFingerprintTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func session(
        id: String = "dp/1",
        startOffset: TimeInterval = 0,
        endOffset: TimeInterval = 8 * 3600,
        stages: [(SleepStage, TimeInterval, TimeInterval)] = [(.deep, 0, 1800), (.light, 1800, 3600)]
    ) -> SleepSession {
        SleepSession(
            id: id,
            start: base.addingTimeInterval(startOffset),
            end: base.addingTimeInterval(endOffset),
            stages: stages.map {
                SleepStageSegment(stage: $0.0, start: base.addingTimeInterval($0.1), end: base.addingTimeInterval($0.2))
            }
        )
    }

    func testFingerprintIsStableForIdenticalContent() {
        XCTAssertEqual(session().contentFingerprint, session().contentFingerprint)
    }

    func testFingerprintIgnoresStageOrder() {
        let forward = session(stages: [(.deep, 0, 1800), (.light, 1800, 3600)])
        let reversed = session(stages: [(.light, 1800, 3600), (.deep, 0, 1800)])
        XCTAssertEqual(forward.contentFingerprint, reversed.contentFingerprint)
    }

    func testFingerprintChangesWhenSessionIsEdited() {
        let original = session()
        XCTAssertNotEqual(original.contentFingerprint, session(endOffset: 9 * 3600).contentFingerprint)
        XCTAssertNotEqual(
            original.contentFingerprint,
            session(stages: [(.deep, 0, 1800), (.rem, 1800, 3600)]).contentFingerprint
        )
        XCTAssertNotEqual(
            original.contentFingerprint,
            session(stages: [(.deep, 0, 1800)]).contentFingerprint
        )
    }

    func testStoreRoundTripsAndOverwrites() {
        let store = InMemorySessionFingerprintStore()
        XCTAssertNil(store.fingerprint(for: "dp/1"))
        store.record("aaa", for: "dp/1")
        XCTAssertEqual(store.fingerprint(for: "dp/1"), "aaa")
        store.record("bbb", for: "dp/1")
        XCTAssertEqual(store.fingerprint(for: "dp/1"), "bbb")
    }

    func testUserDefaultsStorePersistsPerID() {
        let defaults = UserDefaults(suiteName: "fingerprint-tests-\(UUID().uuidString)")!
        let store = UserDefaultsSessionFingerprintStore(defaults: defaults, key: "test.fingerprints")
        store.record(session(id: "a").contentFingerprint, for: "a")
        store.record(session(id: "b", endOffset: 7 * 3600).contentFingerprint, for: "b")
        XCTAssertEqual(store.fingerprint(for: "a"), session(id: "a").contentFingerprint)
        XCTAssertEqual(store.fingerprint(for: "b"), session(id: "b", endOffset: 7 * 3600).contentFingerprint)
        XCTAssertNil(store.fingerprint(for: "c"))
    }
}
