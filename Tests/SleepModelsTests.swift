import XCTest
@testable import AirKit

/// Decode tests for the sleep wire model, using a fixture trimmed from a real
/// Google Health API response (2026-06).
final class SleepModelsTests: XCTestCase {
    /// Two points as they appear on the wire: one Fitbit session and one
    /// mirror of the user's own Apple Watch data (platform HEALTH_KIT).
    private let realShapedJSON = """
    {
      "dataPoints": [
        {
          "name": "users/5949598587409386194/dataTypes/sleep/dataPoints/8423783966740345544",
          "dataSource": {
            "recordingMethod": "DERIVED",
            "device": {},
            "platform": "FITBIT"
          },
          "sleep": {
            "interval": {
              "startTime": "2026-06-09T06:38:00Z",
              "startUtcOffset": "-25200s",
              "endTime": "2026-06-09T14:52:00Z",
              "endUtcOffset": "-25200s"
            },
            "type": "STAGES",
            "stages": [
              {
                "startTime": "2026-06-09T06:38:00Z",
                "startUtcOffset": "-25200s",
                "endTime": "2026-06-09T06:49:00Z",
                "endUtcOffset": "-25200s",
                "type": "AWAKE",
                "createTime": "2026-06-09T15:15:11.589103Z",
                "updateTime": "2026-06-09T15:15:11.589103Z"
              },
              {
                "startTime": "2026-06-09T06:49:00Z",
                "startUtcOffset": "-25200s",
                "endTime": "2026-06-09T07:07:30Z",
                "endUtcOffset": "-25200s",
                "type": "LIGHT",
                "createTime": "2026-06-09T15:15:11.589103Z",
                "updateTime": "2026-06-09T15:15:11.589103Z"
              },
              {
                "startTime": "2026-06-09T07:07:30Z",
                "startUtcOffset": "-25200s",
                "endTime": "2026-06-09T07:58:30Z",
                "endUtcOffset": "-25200s",
                "type": "DEEP",
                "createTime": "2026-06-09T15:15:11.589103Z",
                "updateTime": "2026-06-09T15:15:11.589103Z"
              },
              {
                "startTime": "2026-06-09T07:58:30Z",
                "startUtcOffset": "-25200s",
                "endTime": "2026-06-09T08:10:00Z",
                "endUtcOffset": "-25200s",
                "type": "REM",
                "createTime": "2026-06-09T15:15:11.589103Z",
                "updateTime": "2026-06-09T15:15:11.589103Z"
              }
            ],
            "metadata": {
              "stagesStatus": "SUCCEEDED",
              "processed": true
            },
            "summary": {
              "minutesInSleepPeriod": "494",
              "minutesAsleep": "467",
              "minutesAwake": "27"
            },
            "createTime": "2026-06-09T07:09:13.640079Z",
            "updateTime": "2026-06-09T15:15:18.759615Z"
          }
        },
        {
          "name": "users/5949598587409386194/dataTypes/sleep/dataPoints/6990584730229079136",
          "dataSource": {
            "recordingMethod": "UNKNOWN",
            "application": {
              "packageName": "com.apple.health.EA716DA2-59D5-4CE0-975D-ADFD61799A7F"
            },
            "platform": "HEALTH_KIT"
          },
          "sleep": {
            "interval": {
              "startTime": "2026-06-09T06:59:37.802174Z",
              "startUtcOffset": "-25200s",
              "endTime": "2026-06-09T14:12:27.613870Z",
              "endUtcOffset": "-25200s"
            },
            "type": "STAGES",
            "stages": [
              {
                "startTime": "2026-06-09T06:59:37.802174Z",
                "startUtcOffset": "-25200s",
                "endTime": "2026-06-09T07:02:36.898851Z",
                "endUtcOffset": "-25200s",
                "type": "LIGHT",
                "createTime": "2026-06-09T16:00:43.361375Z",
                "updateTime": "2026-06-09T16:00:43.361375Z"
              }
            ],
            "metadata": {
              "processed": true,
              "externalId": "6990584730229079136"
            }
          }
        }
      ]
    }
    """

    private func decode() throws -> SleepDataPointsResponse {
        try JSONDecoder.googleHealth.decode(SleepDataPointsResponse.self, from: Data(realShapedJSON.utf8))
    }

    func testHealthKitMirrorIsSkipped() throws {
        let sessions = try decode().mapped()
        XCTAssertEqual(sessions.count, 1, "the HEALTH_KIT-platform point must not become a session")
    }

    func testIDComesFromNamePath() throws {
        let session = try XCTUnwrap(decode().mapped().first)
        XCTAssertEqual(session.id, "8423783966740345544")
    }

    func testIntervalParsesAsUTCInstants() throws {
        let session = try XCTUnwrap(decode().mapped().first)
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(session.start, formatter.date(from: "2026-06-09T06:38:00Z"))
        XCTAssertEqual(session.end, formatter.date(from: "2026-06-09T14:52:00Z"))
    }

    func testStageTypesMap() throws {
        let session = try XCTUnwrap(decode().mapped().first)
        XCTAssertEqual(session.stages.map(\.stage), [.wake, .light, .deep, .rem])
    }

    func testStageTimesParse() throws {
        let session = try XCTUnwrap(decode().mapped().first)
        let first = try XCTUnwrap(session.stages.first)
        XCTAssertEqual(first.end.timeIntervalSince(first.start), 11 * 60)
    }

    func testMissingPagesTokenIsNil() throws {
        XCTAssertNil(try decode().nextPageToken)
    }

    func testScreamingCaseStageValuesMap() {
        XCTAssertEqual(SleepStage(wireValue: "AWAKE"), .wake)
        XCTAssertEqual(SleepStage(wireValue: "LIGHT"), .light)
        XCTAssertEqual(SleepStage(wireValue: "DEEP"), .deep)
        XCTAssertEqual(SleepStage(wireValue: "REM"), .rem)
        XCTAssertEqual(SleepStage(wireValue: "ASLEEP"), .asleep)
        XCTAssertEqual(SleepStage(wireValue: "RESTLESS"), .restless)
        XCTAssertEqual(SleepStage(wireValue: "SOMETHING_NEW"), .unknown)
    }
}
