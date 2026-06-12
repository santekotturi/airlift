import XCTest
@testable import AirKit

final class MetricModelsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Decoding (envelope verified against real payloads; interior defensive)

    private func decode(_ json: String) throws -> QuantityDataPointsResponse {
        try JSONDecoder.googleHealth.decode(QuantityDataPointsResponse.self, from: Data(json.utf8))
    }

    private func envelope(id: String, platform: String = "FITBIT", payloadKey: String, payload: String) -> String {
        """
        {"dataPoints":[{"name":"users/123/dataTypes/x/dataPoints/\(id)","dataSource":{"platform":"\(platform)"},"\(payloadKey)":\(payload)}]}
        """
    }

    func testDecodesIntervalAndPlainValue() throws {
        let response = try decode(envelope(
            id: "a",
            payloadKey: "heartRate",
            payload: #"{"interval":{"startTime":"2026-06-07T08:00:00Z","endTime":"2026-06-07T08:01:00Z"},"value":62.5}"#
        ))
        let samples = response.mapped(kind: .heartRate)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].id, "a")
        XCTAssertEqual(samples[0].value, 62.5)
        XCTAssertEqual(samples[0].end.timeIntervalSince(samples[0].start), 60)
    }

    func testDecodesInstantTimeAndFpVal() throws {
        let response = try decode(envelope(
            id: "b",
            payloadKey: "heartRateVariability",
            payload: #"{"time":"2026-06-07T08:00:00Z","fpVal":48.0}"#
        ))
        let samples = response.mapped(kind: .heartRateVariability)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 48.0)
        XCTAssertEqual(samples[0].start, samples[0].end)
    }

    func testDecodesNestedValueObject() throws {
        let response = try decode(envelope(
            id: "c",
            payloadKey: "steps",
            payload: #"{"interval":{"startTime":"2026-06-07T08:00:00Z","endTime":"2026-06-07T09:00:00Z"},"value":{"intVal":850}}"#
        ))
        let samples = response.mapped(kind: .steps)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 850)
    }

    func testHealthKitMirrorPointsAreSkipped() throws {
        let response = try decode(envelope(
            id: "d",
            platform: "HEALTH_KIT",
            payloadKey: "heartRate",
            payload: #"{"time":"2026-06-07T08:00:00Z","value":60}"#
        ))
        XCTAssertTrue(response.mapped(kind: .heartRate).isEmpty)
    }

    func testUnexpectedPayloadKeyStillDecodes() throws {
        // If Google names the payload differently than our guess, fall back to
        // the first payload-shaped object on the point.
        let response = try decode(envelope(
            id: "e",
            payloadKey: "heartRateBpm",
            payload: #"{"time":"2026-06-07T08:00:00Z","value":61}"#
        ))
        let samples = response.mapped(kind: .heartRate)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 61)
    }

    func testPointWithoutValueIsDropped() throws {
        let response = try decode(envelope(
            id: "f",
            payloadKey: "heartRate",
            payload: #"{"time":"2026-06-07T08:00:00Z"}"#
        ))
        XCTAssertTrue(response.mapped(kind: .heartRate).isEmpty)
    }

    func testPointWithoutNameGetsStableSyntheticID() throws {
        // Most quantity points carry no `name` on the wire (verified against
        // real steps/distance payloads) — the dedup ID must be synthesized and
        // identical across re-fetches of the same data.
        let json = """
        {"dataPoints":[{"dataSource":{"platform":"FITBIT"},"heartRate":{"time":"2026-06-07T08:00:00Z","value":60}}]}
        """
        let first = try decode(json).mapped(kind: .heartRate)
        let second = try decode(json).mapped(kind: .heartRate)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].id.hasPrefix("heart_rate|"))
        XCTAssertEqual(first[0].id, second[0].id)
    }

    func testDecodesRealStepsShape() throws {
        // Trimmed from a real payload: string-encoded count, civil time blobs,
        // no name.
        let response = try decode("""
        {"dataPoints":[{"dataSource":{"recordingMethod":"PASSIVELY_MEASURED","platform":"FITBIT"},"steps":{"interval":{"startTime":"2026-06-10T18:30:05.194153Z","startUtcOffset":"-25200s","endTime":"2026-06-10T18:30:07.741193Z","endUtcOffset":"-25200s","civilStartTime":{"date":{"year":2026,"month":6,"day":10}},"civilEndTime":{"date":{"year":2026,"month":6,"day":10}}},"count":"18"}}]}
        """)
        let samples = response.mapped(kind: .steps)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 18)
    }

    func testRealDistanceShapeNormalizesToMeters() throws {
        let response = try decode("""
        {"dataPoints":[{"dataSource":{"platform":"FITBIT"},"distance":{"interval":{"startTime":"2026-06-10T18:30:05Z","endTime":"2026-06-10T18:30:07Z"},"millimeters":"14251"}}]}
        """)
        let samples = response.mapped(kind: .distance)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 14.251, accuracy: 0.0001)
    }

    func testEndpointPathsAreKebabCaseAndFiltersSnakeCase() {
        XCTAssertEqual(MetricKind.heartRate.googleDataTypePath, "heart-rate")
        XCTAssertEqual(MetricKind.heartRate.filterMember, "heart_rate")
        XCTAssertEqual(MetricKind.restingHeartRate.googleDataTypePath, "daily-resting-heart-rate")
        XCTAssertEqual(MetricKind.respiratoryRate.googleDataTypePath, "daily-respiratory-rate")
        for kind in MetricKind.allCases {
            XCTAssertFalse(kind.googleDataTypePath.contains("_"), "\(kind) path must be kebab-case")
            XCTAssertFalse(kind.filterMember.contains("-"), "\(kind) filter member must be snake_case")
        }
    }

    // MARK: - Verified real shapes (sampleTime + daily date payloads)

    func testDecodesRealHeartRateShape() throws {
        let response = try decode("""
        {"dataPoints":[{"dataSource":{"recordingMethod":"PASSIVELY_MEASURED","device":{},"platform":"FITBIT"},"heartRate":{"sampleTime":{"physicalTime":"2026-06-10T20:18:15Z","utcOffset":"-25200s","civilTime":{"date":{"year":2026,"month":6,"day":10}}},"beatsPerMinute":"66"}}]}
        """)
        let samples = response.mapped(kind: .heartRate)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 66)
        XCTAssertEqual(samples[0].start, ISO8601DateFormatter().date(from: "2026-06-10T20:18:15Z"))
        XCTAssertEqual(samples[0].start, samples[0].end)
    }

    func testFitbitHRVPicksRMSSDAndSkipsZeros() throws {
        // Fitbit points carry RMSSD only; mirrored Apple points carry
        // rmssd: 0 next to a real SDNN — zeros must never become samples.
        let response = try decode("""
        {"dataPoints":[
          {"dataSource":{"platform":"FITBIT"},"heartRateVariability":{"sampleTime":{"physicalTime":"2026-06-09T14:45:00Z"},"rootMeanSquareOfSuccessiveDifferencesMilliseconds":56.6}},
          {"dataSource":{"platform":"FITBIT"},"heartRateVariability":{"sampleTime":{"physicalTime":"2026-06-09T14:50:00Z"},"rootMeanSquareOfSuccessiveDifferencesMilliseconds":0,"standardDeviationMilliseconds":120.5}}
        ]}
        """)
        let samples = response.mapped(kind: .heartRateVariability)
        XCTAssertEqual(samples.map(\.value), [56.6, 120.5])
    }

    func testRealSpO2PercentageNormalizes() throws {
        let response = try decode("""
        {"dataPoints":[{"dataSource":{"platform":"FITBIT"},"oxygenSaturation":{"sampleTime":{"physicalTime":"2026-06-10T19:15:12Z"},"percentage":96}}]}
        """)
        let samples = response.mapped(kind: .oxygenSaturation)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 0.96, accuracy: 0.0001)
    }

    func testDailyRestingHeartRateSpansLocalDay() throws {
        let response = try decode("""
        {"dataPoints":[{"dataSource":{"platform":"FITBIT"},"dailyRestingHeartRate":{"date":{"year":2026,"month":6,"day":9},"beatsPerMinute":"53"}}]}
        """)
        let samples = response.mapped(kind: .restingHeartRate)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 53)
        XCTAssertEqual(samples[0].start, Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 9)))
        XCTAssertEqual(samples[0].end.timeIntervalSince(samples[0].start), 86_400)
        XCTAssertTrue(samples[0].id.contains("2026-6-9"), "daily IDs must be date-stable, got \(samples[0].id)")
    }

    func testDailyRespiratoryRateDecodes() throws {
        let response = try decode("""
        {"dataPoints":[{"dataSource":{"platform":"FITBIT"},"dailyRespiratoryRate":{"date":{"year":2026,"month":6,"day":9},"breathsPerMinute":13.488}}]}
        """)
        let samples = response.mapped(kind: .respiratoryRate)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 13.488, accuracy: 0.0001)
    }

    func testSpO2SentinelValuesAreDropped() throws {
        // Fitbit emits percentage == 50 as a "no valid reading" sentinel.
        let response = try decode("""
        {"dataPoints":[
          {"dataSource":{"platform":"FITBIT"},"oxygenSaturation":{"sampleTime":{"physicalTime":"2026-06-09T07:26:04Z"},"percentage":50}},
          {"dataSource":{"platform":"FITBIT"},"oxygenSaturation":{"sampleTime":{"physicalTime":"2026-06-09T07:27:04Z"},"percentage":96}}
        ]}
        """)
        let samples = response.mapped(kind: .oxygenSaturation)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 0.96, accuracy: 0.0001)
    }

    func testCumulativeComparisonPrefersDedupedAppleTotal() {
        // Raw Apple samples double-count iPhone + Watch; the deduplicated
        // total provided by HealthKit must win the comparison.
        let google = [sample("g", value: 8000)]
        let doubleCounted = [apple(7800), apple(7600, minute: 1)] // naive sum: 15400 → bogus warn
        let results = SanityChecks.runMetric(kind: .steps, samples: google, apple: doubleCounted, appleTotal: 7800)
        let comparison = results.first { $0.name == "Apple comparison" }
        XCTAssertEqual(comparison?.severity, .pass)
        XCTAssertTrue(comparison?.detail.contains("deduplicated") == true)
    }

    // MARK: - Downsampling (3-second Fitbit HR → minute averages)

    func testDownsamplingAveragesPerMinuteBucket() {
        let minute = Date(timeIntervalSinceReferenceDate: 1_000_020) // not minute-aligned
        let samples = [
            MetricSample(id: "a", start: minute, end: minute, value: 60),
            MetricSample(id: "b", start: minute.addingTimeInterval(3), end: minute.addingTimeInterval(3), value: 70),
            MetricSample(id: "c", start: minute.addingTimeInterval(65), end: minute.addingTimeInterval(65), value: 100),
        ]
        let buckets = samples.downsampled(bucket: 60, kind: .heartRate)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].value, 65)
        XCTAssertEqual(buckets[1].value, 100)
        XCTAssertEqual(buckets[0].end.timeIntervalSince(buckets[0].start), 60)
        XCTAssertEqual(buckets[0].start.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60), 0, "buckets must be minute-aligned")
    }

    func testDownsamplingIDsAreStableAcrossRefetches() {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_020)
        let first = [MetricSample(id: "x1", start: t, end: t, value: 61)]
            .downsampled(bucket: 60, kind: .heartRate)
        let refetched = [MetricSample(id: "x2", start: t.addingTimeInterval(2), end: t.addingTimeInterval(2), value: 63)]
            .downsampled(bucket: 60, kind: .heartRate)
        XCTAssertEqual(first[0].id, refetched[0].id, "same minute must dedupe across re-fetches")
    }

    func testDownsamplingSumsCumulativeBuckets() {
        let hour = Date(timeIntervalSinceReferenceDate: 3_600_000) // hour-aligned
        let samples = [
            MetricSample(id: "a", start: hour, end: hour.addingTimeInterval(60), value: 100),
            MetricSample(id: "b", start: hour.addingTimeInterval(120), end: hour.addingTimeInterval(180), value: 250),
            MetricSample(id: "c", start: hour.addingTimeInterval(3700), end: hour.addingTimeInterval(3760), value: 40),
        ]
        let buckets = samples.downsampled(bucket: 3600, kind: .steps, aggregation: .sum)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].value, 350)
        XCTAssertEqual(buckets[1].value, 40)
    }

    func testOnlyHeartRateDownsamples() {
        XCTAssertEqual(MetricKind.heartRate.downsampleBucketSeconds, TimeInterval(60))
        for kind in MetricKind.allCases where kind != MetricKind.heartRate {
            XCTAssertNil(kind.downsampleBucketSeconds)
        }
    }

    func testOldestStartFindsPageMinimum() throws {
        let response = try decode("""
        {"dataPoints":[
          {"dataSource":{"platform":"FITBIT"},"steps":{"interval":{"startTime":"2026-06-10T08:00:00Z","endTime":"2026-06-10T08:01:00Z"},"count":"5"}},
          {"dataSource":{"platform":"HEALTH_KIT"},"steps":{"interval":{"startTime":"2026-06-08T08:00:00Z","endTime":"2026-06-08T08:01:00Z"},"count":"7"}}
        ]}
        """)
        // Mirrors are skipped in mapped() but still count for the page cutoff.
        let oldest = try XCTUnwrap(response.oldestStart(kind: .steps))
        XCTAssertEqual(oldest, ISO8601DateFormatter().date(from: "2026-06-08T08:00:00Z"))
    }

    // MARK: - Normalization

    func testSpO2PercentPointsNormalizedToFraction() {
        XCTAssertEqual(MetricKind.oxygenSaturation.normalize(97), 0.97, accuracy: 0.0001)
        XCTAssertEqual(MetricKind.oxygenSaturation.normalize(0.97), 0.97, accuracy: 0.0001)
    }

    func testOtherKindsPassThrough() {
        XCTAssertEqual(MetricKind.heartRate.normalize(62), 62)
        XCTAssertEqual(MetricKind.steps.normalize(8000), 8000)
    }

    // MARK: - Metric sanity checks

    private func sample(_ id: String, value: Double, minute: Int = 0) -> MetricSample {
        MetricSample(id: id, start: base.addingTimeInterval(Double(minute) * 60), end: base.addingTimeInterval(Double(minute) * 60), value: value)
    }

    private func apple(_ value: Double, minute: Int = 0) -> QuantitySample {
        QuantitySample(id: UUID(), start: base.addingTimeInterval(Double(minute) * 60), end: base.addingTimeInterval(Double(minute) * 60), value: value)
    }

    func testEmptyBatchFails() {
        let results = SanityChecks.runMetric(kind: .heartRate, samples: [], apple: [])
        XCTAssertEqual(results.first?.severity, .fail)
    }

    func testOutOfRangeValuesWarn() {
        // SpO2 of 97 (un-normalized percent points) is out of the 0.7...1.0 range.
        let results = SanityChecks.runMetric(kind: .oxygenSaturation, samples: [sample("a", value: 97)], apple: [])
        let range = results.first { $0.name == "Value range" }
        XCTAssertEqual(range?.severity, .warn)
    }

    func testMatchingAveragesPass() {
        let google = (0..<10).map { sample("g\($0)", value: 60, minute: $0) }
        let appleSamples = (0..<10).map { apple(62, minute: $0) }
        let results = SanityChecks.runMetric(kind: .heartRate, samples: google, apple: appleSamples)
        let comparison = results.first { $0.name == "Apple comparison" }
        XCTAssertEqual(comparison?.severity, .pass)
    }

    func testDivergentAveragesWarn() {
        let google = [sample("g", value: 120)]
        let appleSamples = [apple(60)]
        let results = SanityChecks.runMetric(kind: .heartRate, samples: google, apple: appleSamples)
        let comparison = results.first { $0.name == "Apple comparison" }
        XCTAssertEqual(comparison?.severity, .warn)
    }

    func testCumulativeComparesTotals() {
        // Google 8000 steps in two samples vs Apple 7800 → within 30%, pass.
        let google = [sample("g1", value: 5000), sample("g2", value: 3000, minute: 60)]
        let appleSamples = [apple(7800)]
        let results = SanityChecks.runMetric(kind: .steps, samples: google, apple: appleSamples)
        let comparison = results.first { $0.name == "Apple comparison" }
        XCTAssertEqual(comparison?.severity, .pass)
    }

    func testHRVDivergenceIsInfoNotWarn() {
        // Google RMSSD ~45ms vs Apple SDNN ~110ms — expected divergence,
        // should surface the values without warning.
        let google = [sample("g", value: 45)]
        let appleSamples = [apple(110)]
        let results = SanityChecks.runMetric(kind: .heartRateVariability, samples: google, apple: appleSamples)
        let comparison = results.first { $0.name == "Apple comparison" }
        XCTAssertEqual(comparison?.severity, .info)
        XCTAssertTrue(comparison!.detail.contains("RMSSD"), comparison!.detail)
    }

    func testNoAppleDataIsInfo() {
        let results = SanityChecks.runMetric(kind: .respiratoryRate, samples: [sample("a", value: 14)], apple: [])
        let appleCheck = results.first { $0.name == "Apple Watch" }
        XCTAssertEqual(appleCheck?.severity, .info)
    }
}
