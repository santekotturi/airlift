import XCTest
@testable import Airlift

final class DumpStoreTests: XCTestCase {
    private var root: URL!
    private var store: DumpStore!
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlift-dumps-\(UUID().uuidString)", isDirectory: true)
        store = DumpStore(root: root)
        store.beginFetch(now: now)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var fetchFolder: URL {
        get throws {
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            XCTAssertEqual(folders.count, 1)
            return folders[0]
        }
    }

    private func fileNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: fetchFolder.path))
    }

    func testRawPagesAreNumberedPerDataType() throws {
        store.writeRawPage(Data("{\"a\":1}".utf8), dataType: "sleep")
        store.writeRawPage(Data("{\"a\":2}".utf8), dataType: "sleep")
        store.writeRawPage(Data("{\"b\":1}".utf8), dataType: "heart_rate")
        XCTAssertEqual(
            try fileNames(),
            ["google-sleep-page1.json", "google-sleep-page2.json", "google-heart_rate-page1.json"]
        )
    }

    func testBeginFetchStartsNewFolderAndResetsPaging() throws {
        store.writeRawPage(Data("{}".utf8), dataType: "sleep")
        store.beginFetch(now: now.addingTimeInterval(60))
        store.writeRawPage(Data("{}".utf8), dataType: "sleep")
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 2)
        for folder in folders {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["google-sleep-page1.json"])
        }
    }

    func testStagedSessionDumpIsValidJSON() throws {
        let session = SleepSession(
            id: "dp/123:abc",
            start: now,
            end: now.addingTimeInterval(8 * 3600),
            stages: [SleepStageSegment(stage: .deep, start: now, end: now.addingTimeInterval(1800))]
        )
        let item = StagedSession(
            session: session,
            appleSleep: [],
            heartRate: [HRSample(id: UUID(), date: now, bpm: 52)],
            checks: [CheckResult(name: "Duration", severity: .pass, detail: "8.0 h")]
        )
        store.writeStagedSession(item)

        let names = try fileNames()
        XCTAssertEqual(names.count, 1)
        let name = try XCTUnwrap(names.first)
        XCTAssertTrue(name.hasPrefix("staged-sleep-"), "unexpected name \(name)")
        XCTAssertFalse(name.contains("/"))

        let data = try Data(contentsOf: fetchFolder.appendingPathComponent(name))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["googleSessionID"] as? String, "dp/123:abc")
        XCTAssertEqual((object["stages"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((object["appleHeartRate"] as? [[String: Any]])?.count, 1)
    }

    func testStagedMetricBatchDumpIsValidJSON() throws {
        let sample = MetricSample(id: "m1", start: now, end: now, value: 61)
        let batch = StagedMetricBatch(
            kind: .heartRate,
            day: now,
            samples: [sample],
            appleSamples: [QuantitySample(id: UUID(), start: now, end: now, value: 60)],
            checks: SanityChecks.runMetric(kind: .heartRate, samples: [sample], apple: [])
        )
        store.writeStagedBatch(batch)

        let names = try fileNames()
        XCTAssertEqual(names.count, 1)
        let name = try XCTUnwrap(names.first)
        XCTAssertTrue(name.hasPrefix("staged-heart_rate-"), "unexpected name \(name)")

        let data = try Data(contentsOf: fetchFolder.appendingPathComponent(name))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "heart_rate")
        XCTAssertEqual((object["googleSamples"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((object["appleSamples"] as? [[String: Any]])?.count, 1)
        XCTAssertFalse((object["checks"] as? [[String: Any]] ?? []).isEmpty)
    }

    func testWritesBeforeBeginFetchAreDropped() throws {
        let fresh = DumpStore(root: root.appendingPathComponent("other"))
        fresh.writeRawPage(Data("{}".utf8), dataType: "sleep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("other").path))
    }
}
